// Port of ../editor/src/terminal.zig onto zigui's existing custom-element API.
const std = @import("std");
const vt = @import("ghostty-vt");
const ui = @import("zigui");
const g = ui.geometry;
const Pty = @import("pty.zig").Pty;
const boxes = @import("box_drawing.zig");
const cache = @import("render_cache.zig");
pub const font_size: f32 = 13;
pub const line_height: f32 = 20;

/// Stable VT/stream owner. The terminal is embedded so response callbacks can
/// recover this instance without the editor's global response_binding variable.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    render_state: vt.RenderState = .empty,
    fonts: *ui.TextSystem,
    font_ids: [4]ui.FontId,
    pty: ?*Pty = null,
    columns: u16 = 80,
    rows: u16 = 24,
    cell_width: f32,
    baseline: f32,
    metrics: ui.platform.Metrics,
    focused: bool = true,
    scroll_remainder: f32 = 0,
    pressed_buttons: u8 = 0,
    last_button: ?vt.input.MouseButton = null,
    last_mouse_cell: ?vt.Coordinate = null,
    preedit: []const u8 = "",
    preedit_selection: ui.input.TextRange = .{ .location = 0, .length = 0 },
    writes: std.ArrayList(u8) = .empty,
    response_error: ?anyerror = null,
    /// Changes only when a visible property changes, independently of input handling.
    visual_revision: u64 = 0,
    render_initialized: bool = false,
    row_cache: cache.Rows,
    shapes: cache.Shapes,
    row_key: ?RowKey = null,
    shape_generation: u64,
    /// All non-row-data inputs that affect retained row primitives.
    const RowKey = struct {
        columns: u16,
        cell_width: f32,
        baseline: f32,
        scale: f32,
        font_generation: u64,
        foreground: vt.color.RGB,
        background: vt.color.RGB,
        palette: vt.color.Palette,
    };
    /// Only cursor properties used by paintCursor; current SGR state and blink
    /// bookkeeping do not themselves change this example's steady cursor image.
    const CursorPaint = struct { viewport: vt.RenderState.Cursor.Viewport, style: @FieldType(vt.RenderState.Cursor, "visual_style") };
    fn paintedCursor(self: *const Engine) ?CursorPaint {
        if (!self.render_state.cursor.visible) return null;
        return .{ .viewport = self.render_state.cursor.viewport orelse return null, .style = if (self.focused) self.render_state.cursor.visual_style else .block_hollow };
    }

    pub fn create(a: std.mem.Allocator, io: std.Io, fonts: *ui.TextSystem) !*Engine {
        const self = try a.create(Engine);
        errdefer a.destroy(self);
        var ids: [4]ui.FontId = undefined;
        for (&ids, 0..) |*id, index| id.* = try fonts.fontId(.{ .family = "Menlo", .weight = if (index & 1 != 0) .bold else .normal, .style = if (index & 2 != 0) .italic else .normal });
        const measured = try fonts.shapeLine("M", font_size, &.{.{ .len = 1, .font_id = ids[0] }});
        defer measured.release();
        self.* = .{
            .allocator = a,
            .terminal = try .init(io, a, .{ .cols = 80, .rows = 24 }),
            .stream = undefined,
            .fonts = fonts.retain(),
            .font_ids = ids,
            .cell_width = @ceil(measured.width),
            .baseline = (line_height - measured.ascent - measured.descent) / 2 + measured.ascent,
            .metrics = .{ .size = .{ .width = @ceil(measured.width) * 80, .height = line_height * 24 }, .scale = 1 },
            .row_cache = .init(a),
            .shapes = .init(a),
            .shape_generation = fonts.generation,
        };
        errdefer {
            self.terminal.deinit(a);
            self.fonts.release();
        }
        var handler = self.terminal.vtHandler();
        handler.effects.write_pty = writeResponse;
        handler.terminfo_name = "xterm-256color";
        self.stream = .init(.{ .allocator = a, .handler = handler });
        errdefer self.stream.deinit();
        errdefer self.render_state.deinit(a);
        try self.refresh();
        return self;
    }
    pub fn destroy(self: *Engine) void {
        // Stream teardown may abort protocol transactions; no callbacks may use
        // a PTY that has already been stopped and freed.
        self.stream.handler.effects.write_pty = null;
        if (self.pty) |pty| pty.destroy();
        self.pty = null;
        self.row_cache.deinit();
        self.shapes.deinit();
        self.render_state.deinit(self.allocator);
        self.stream.deinit();
        self.terminal.deinit(self.allocator);
        self.fonts.release();
        self.allocator.free(self.preedit);
        self.writes.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    fn writeResponse(handler: *vt.TerminalStream.Handler, bytes: []const u8) void {
        const self: *Engine = @fieldParentPtr("terminal", handler.terminal);
        self.write(bytes) catch |err| {
            if (err != error.PtyClosed) self.response_error = err;
        };
    }
    pub fn write(self: *Engine, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (self.pty) |pty| try pty.write(bytes) else try self.writes.appendSlice(self.allocator, bytes);
    }
    pub fn refresh(self: *Engine) !void {
        const cursor = self.paintedCursor();
        const colors = self.render_state.colors;
        // RenderState.dirty is sticky until consumed. Inspect just this update's
        // changes, then merge back pending work so multiple PTY batches accumulate.
        const pending = self.render_state.dirty;
        self.render_state.dirty = .false;
        errdefer self.render_state.dirty = .full;
        try self.render_state.update(self.allocator, &self.terminal);
        const changed = !self.render_initialized or self.render_state.dirty != .false or
            !std.meta.eql(cursor, self.paintedCursor()) or !std.meta.eql(colors, self.render_state.colors);
        if (pending == .full) self.render_state.dirty = .full else if (pending == .partial and self.render_state.dirty == .false) self.render_state.dirty = .partial;
        self.render_initialized = true;
        if (changed) self.visual_revision +%= 1;
    }
    fn prepareRows(self: *Engine, scale: f32) !void {
        if (self.shape_generation != self.fonts.generation) {
            self.shapes.clear();
            self.shape_generation = self.fonts.generation;
        }
        const render_key = RowKey{ .columns = self.columns, .cell_width = self.cell_width, .baseline = self.baseline, .scale = scale, .font_generation = self.fonts.generation, .foreground = self.render_state.colors.foreground, .background = self.render_state.colors.background, .palette = self.render_state.colors.palette };
        // A VT full update marks all rows dirty, but equal cell contents can
        // still be reused. Geometry/font/color changes require unconditional rebuilds.
        const full = self.row_key == null or !std.meta.eql(self.row_key.?, render_key);
        const dirty = self.render_state.row_data.items(.dirty);
        var builder = Grid{ .engine = self };
        try self.row_cache.update(dirty[0..@min(dirty.len, self.rows)], full, &builder, scale);
        self.row_key = render_key;
        self.render_state.dirty = .false;
    }
    fn scrollToBottom(self: *Engine) !void {
        if (self.terminal.screens.active.pages.viewport == .active) return;
        self.terminal.scrollViewport(.bottom);
        try self.refresh();
    }
    pub fn feed(self: *Engine, bytes: []const u8) !void {
        const old_mouse_event = self.terminal.flags.mouse_event;
        const old_mouse_format = self.terminal.flags.mouse_format;
        self.stream.nextSlice(bytes);
        if (old_mouse_event != self.terminal.flags.mouse_event or old_mouse_format != self.terminal.flags.mouse_format) self.last_mouse_cell = null;
        if (self.stream.handler.semantic_failure) return error.TerminalParseFailed;
        if (self.response_error) |err| return err;
        try self.refresh();
    }
    pub fn resize(self: *Engine, metrics: ui.platform.Metrics) !void {
        const changed = !std.meta.eql(self.metrics, metrics);
        const measured = try self.fonts.shapeLine("M", font_size, &.{.{ .len = 1, .font_id = self.font_ids[0] }});
        defer measured.release();
        const width = @ceil(measured.width * metrics.scale) / metrics.scale;
        const cols: u16 = @intFromFloat(@min(4096, @max(1, @floor(metrics.size.width / width))));
        const rows: u16 = @intFromFloat(@min(2048, @max(1, @floor(metrics.size.height / line_height))));
        const pixels = struct {
            fn value(v: f32) u16 {
                return @intFromFloat(@min(65535, @max(1, @ceil(v))));
            }
        };
        if (self.columns != cols or self.rows != rows or self.metrics.scale != metrics.scale) {
            try self.terminal.resize(self.allocator, .{ .cols = cols, .rows = rows, .cell_size_px = .{ .width = pixels.value(width * metrics.scale), .height = pixels.value(line_height * metrics.scale) } });
        }
        if (self.pty) |pty| try pty.resize(cols, rows, pixels.value(metrics.size.width * metrics.scale), pixels.value(metrics.size.height * metrics.scale));
        self.columns = cols;
        self.rows = rows;
        self.cell_width = width;
        self.metrics = metrics;
        self.last_mouse_cell = null;
        try self.refresh();
        if (changed) self.visual_revision +%= 1;
    }
    pub fn paste(self: *Engine, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        defer self.allocator.free(copy);
        const parts = vt.input.encodePaste(copy, .fromTerminal(&self.terminal));
        for (parts) |part| try self.write(part);
        try self.scrollToBottom();
    }
    pub fn focus(self: *Engine, focused: bool) !void {
        if (self.focused == focused) return;
        const cursor = self.paintedCursor();
        self.focused = focused;
        if (!std.meta.eql(cursor, self.paintedCursor())) self.visual_revision +%= 1;
        if (!focused) {
            self.pressed_buttons = 0;
            self.last_button = null;
            self.last_mouse_cell = null;
        }
        if (self.terminal.modes.get(.focus_event)) try self.write(if (focused) "\x1b[I" else "\x1b[O");
    }
    pub fn event(self: *Engine, value: ui.input.PlatformInput) !bool {
        switch (value) {
            .key_down, .key_up => |key_event| return self.key(key_event, value == .key_up),
            .text => |text| {
                try self.write(text.text);
                try self.setPreedit("");
                try self.scrollToBottom();
                return true;
            },
            .marked_text => |composition| {
                try self.setPreedit(composition.text);
                self.preedit_selection = composition.selection;
                return true;
            },
            .unmark_text => {
                try self.setPreedit("");
                return true;
            },
            .scroll => |scroll| {
                self.scroll_remainder += if (scroll.precise) scroll.delta.y / line_height else scroll.delta.y;
                const delta: isize = @intFromFloat(std.math.clamp(@trunc(self.scroll_remainder), -100, 100));
                self.scroll_remainder -= @floatFromInt(delta);
                if (delta != 0) {
                    if (self.terminal.flags.mouse_event != .none and !scroll.modifiers.shift) {
                        for (0..@abs(delta)) |_| _ = try self.encodeMouse(.press, if (delta > 0) .four else .five, scroll.position, scroll.modifiers);
                    } else if (self.render_state.screen == .alternate and self.terminal.modes.get(.mouse_alternate_scroll)) {
                        for (0..@abs(delta)) |_| _ = try self.key(.{ .key = if (delta > 0) "up" else "down", .key_code = if (delta > 0) 126 else 125, .modifiers = scroll.modifiers }, false);
                    } else {
                        self.terminal.scrollViewport(.{ .delta = -delta });
                        try self.refresh();
                    }
                }
                return true;
            },
            .mouse_down, .mouse_up, .mouse_move, .mouse_exit => |mouse| {
                const button: ?vt.input.MouseButton = if (mouse.button) |button| switch (button) {
                    .left => .left,
                    .right => .right,
                    .middle => .middle,
                    .back => .eight,
                    .forward => .nine,
                    .other => .unknown,
                } else null;
                if (mouse.button) |physical| {
                    const mask = @as(u8, 1) << @intCast(@intFromEnum(physical));
                    if (value == .mouse_down) {
                        self.pressed_buttons |= mask;
                        self.last_button = button;
                    }
                    if (value == .mouse_up) {
                        self.pressed_buttons &= ~mask;
                    }
                }
                const action: vt.input.MouseAction = if (value == .mouse_down) .press else if (value == .mouse_up) .release else .motion;
                return self.encodeMouse(action, button orelse (if (self.pressed_buttons != 0) self.last_button else null), mouse.position, mouse.modifiers);
            },
            else => return false,
        }
    }
    fn encodeMouse(self: *Engine, action: vt.input.MouseAction, button: ?vt.input.MouseButton, position: g.Point, modifiers: ui.input.Modifiers) !bool {
        if (self.terminal.flags.mouse_event == .none) return false;
        var options = vt.input.MouseEncodeOptions.fromTerminal(&self.terminal, .{
            .screen = .{ .width = @intFromFloat(@max(1, @ceil(self.metrics.size.width * self.metrics.scale))), .height = @intFromFloat(@max(1, @ceil(self.metrics.size.height * self.metrics.scale))) },
            .cell = .{ .width = @intFromFloat(@max(1, @round(self.cell_width * self.metrics.scale))), .height = @intFromFloat(@max(1, @round(line_height * self.metrics.scale))) },
            .padding = .{},
        });
        options.any_button_pressed = self.pressed_buttons != 0;
        options.last_cell = &self.last_mouse_cell;
        var buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try vt.input.encodeMouse(&writer, .{
            .action = action,
            .button = button,
            .mods = .{ .shift = modifiers.shift, .ctrl = modifiers.control, .alt = modifiers.alt, .super = modifiers.command },
            .pos = .{ .x = position.x * self.metrics.scale, .y = position.y * self.metrics.scale },
        }, options);
        try self.write(writer.buffered());
        return true;
    }
    fn setPreedit(self: *Engine, value: []const u8) !void {
        if (std.mem.eql(u8, self.preedit, value)) return;
        const copy = try self.allocator.dupe(u8, value);
        self.allocator.free(self.preedit);
        self.preedit = copy;
        self.visual_revision +%= 1;
        if (value.len == 0) self.preedit_selection = .{ .location = 0, .length = 0 };
    }
    fn key(self: *Engine, event_value: ui.input.KeyEvent, release: bool) !bool {
        if (self.preedit.len > 0) return false;
        var options = vt.input.KeyEncodeOptions.fromTerminal(&self.terminal);
        options.macos_option_as_alt = .true;
        options.alt_esc_prefix = true;
        const physical = physicalKey(event_value.key_code, event_value.key);
        const named = logicalKey(event_value.key);
        const printable = event_value.key.len > 0 and (named == null or named.? == .space);
        if (!release and printable and !event_value.modifiers.control and !event_value.modifiers.alt and !event_value.modifiers.command and !options.kitty_flags.report_all) return false;
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        const bytes: []const u8 = if (std.mem.eql(u8, event_value.key, "space")) " " else if (printable) event_value.key else "";
        const cp = if (bytes.len > 0) blk: {
            var iter = (try std.unicode.Utf8View.init(bytes)).iterator();
            const code = iter.nextCodepoint().?;
            break :blk if (code < 128) @as(u21, std.ascii.toLower(@intCast(code))) else code;
        } else 0;
        try vt.input.encodeKey(&writer, .{
            .action = if (release) .release else if (event_value.is_repeat) .repeat else .press,
            .key = physical,
            .utf8 = bytes,
            .unshifted_codepoint = cp,
            .mods = .{ .shift = event_value.modifiers.shift, .ctrl = event_value.modifiers.control, .alt = event_value.modifiers.alt, .super = event_value.modifiers.command, .caps_lock = event_value.modifiers.caps_lock },
            .consumed_mods = .{ .shift = bytes.len > 0 and event_value.modifiers.shift },
        }, options);
        try self.write(writer.buffered());
        if (!release and writer.buffered().len > 0) {
            try self.scrollToBottom();
        }
        return true;
    }
    pub fn cursorBounds(self: *const Engine) ?g.Bounds {
        const cursor = self.render_state.cursor.viewport orelse return null;
        return .{ .origin = .{ .x = @as(f32, @floatFromInt(cursor.x)) * self.cell_width, .y = @as(f32, @floatFromInt(cursor.y)) * line_height }, .size = .{ .width = self.cell_width, .height = line_height } };
    }
};

fn logicalKey(name: []const u8) ?vt.input.Key {
    const Special = struct { name: []const u8, key: vt.input.Key };
    for ([_]Special{ .{ .name = "left", .key = .arrow_left }, .{ .name = "right", .key = .arrow_right }, .{ .name = "up", .key = .arrow_up }, .{ .name = "down", .key = .arrow_down }, .{ .name = "pageup", .key = .page_up }, .{ .name = "pagedown", .key = .page_down } }) |special| if (std.mem.eql(u8, name, special.name)) return special.key;
    return std.meta.stringToEnum(vt.input.Key, name);
}
fn physicalKey(code: u16, name: []const u8) vt.input.Key {
    if (logicalKey(name)) |key| return key;
    // macOS virtual-key positions, independent of the text produced by the layout.
    const ascii = [_]u8{ 'a', 's', 'd', 'f', 'h', 'g', 'z', 'x', 'c', 'v', 0, 'b', 'q', 'w', 'e', 'r', 'y', 't', '1', '2', '3', '4', '6', '5', '=', '9', '7', '-', '8', '0', ']', 'o', 'u', '[', 'i', 'p', 0, 'l', 'j', '\'', 'k', ';', '\\', ',', '/', 'n', 'm', '.', 0, ' ', '`' };
    if (code < ascii.len) {
        const ch = ascii[code];
        if (ch >= 'a' and ch <= 'z') return @enumFromInt(@intFromEnum(vt.input.Key.key_a) + ch - 'a');
        if (ch >= '0' and ch <= '9') return @enumFromInt(@intFromEnum(vt.input.Key.digit_0) + ch - '0');
        return switch (ch) {
            '[' => .bracket_left,
            ']' => .bracket_right,
            '\\' => .backslash,
            '/' => .slash,
            '-' => .minus,
            '=' => .equal,
            ';' => .semicolon,
            '\'' => .quote,
            ',' => .comma,
            '.' => .period,
            '`' => .backquote,
            ' ' => .space,
            else => .unidentified,
        };
    }
    return .unidentified;
}

/// App-owned wrapper for the mutable terminal engine; updates happen on the UI thread.
pub const Model = struct {
    engine: *Engine,
    /// Synchronous dispatch argument; handled points to the host's stack result.
    pub const Input = struct { event: ui.input.PlatformInput, handled: *bool };
    pub fn deinit(self: *Model) void {
        self.engine.destroy();
    }
    pub fn render(self: *const Model, f: *ui.Frame, _: *ui.Context(Model)) !ui.AnyElement {
        return f.element(Grid{ .engine = self.engine });
    }
    pub fn resize(self: *Model, metrics: ui.platform.Metrics, cx: *ui.Context(Model)) !void {
        const before = self.engine.visual_revision;
        const result = self.engine.resize(metrics);
        if (self.engine.visual_revision != before) try cx.notify();
        try result;
    }
    pub fn output(self: *Model, bytes: []const u8, cx: *ui.Context(Model)) !void {
        const before = self.engine.visual_revision;
        const result = self.engine.feed(bytes);
        if (self.engine.visual_revision != before) try cx.notify();
        try result;
    }
    pub fn focus(self: *Model, focused: bool, cx: *ui.Context(Model)) !void {
        const before = self.engine.visual_revision;
        const result = self.engine.focus(focused);
        if (self.engine.visual_revision != before) try cx.notify();
        try result;
    }
    pub fn input(self: *Model, args: Input, cx: *ui.Context(Model)) !void {
        const before = self.engine.visual_revision;
        const result = self.engine.event(args.event);
        if (self.engine.visual_revision != before) try cx.notify();
        args.handled.* = try result;
    }
    pub fn paste(self: *Model, bytes: []const u8, cx: *ui.Context(Model)) !void {
        const before = self.engine.visual_revision;
        const result = self.engine.paste(bytes);
        if (self.engine.visual_revision != before) try cx.notify();
        try result;
    }
};

/// Full-viewport grid that replays retained row scenes. Cursor and preedit remain
/// independent overlays, so moving either does not rebuild unchanged text rows.
pub const Grid = struct {
    pub const RequestLayoutState = void;
    pub const PrepaintState = g.Bounds;
    engine: *Engine,
    pub fn requestLayout(_: *Grid, f: *ui.Frame) !ui.LayoutRequest(void) {
        return .{ .id = try f.layout.request(.{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 } }, &.{}), .state = {} };
    }
    pub fn prepaint(_: *Grid, f: *ui.Frame, bounds: g.Bounds, _: *void) !g.Bounds {
        try f.hitbox(1, bounds);
        return bounds.intersect(f.clip);
    }
    pub fn paint(self: *Grid, f: *ui.Frame, bounds: g.Bounds, _: *void, clip: *g.Bounds) !void {
        const old_clip = f.clip;
        f.clip = clip.*;
        defer f.clip = old_clip;
        const engine = self.engine;
        try engine.prepareRows(f.scale);
        try fill(f, bounds, color(engine.render_state.colors.background));
        try engine.row_cache.paint(f, bounds.origin, line_height);
        try self.paintCursor(f, bounds);
        if (engine.preedit.len > 0) if (engine.cursorBounds()) |cursor| {
            const line = try engine.fonts.shapeLine(engine.preedit, font_size, &.{.{ .len = engine.preedit.len, .font_id = engine.font_ids[0] }});
            defer line.release();
            const cell = g.Bounds{ .origin = .{ .x = bounds.origin.x + cursor.origin.x, .y = bounds.origin.y + cursor.origin.y }, .size = .{ .width = @max(engine.cell_width, line.width), .height = line_height } };
            try fill(f, cell, color(engine.render_state.colors.background));
            try self.paintLine(f, cell, line, color(engine.render_state.colors.foreground));
            try fill(f, .{ .origin = .{ .x = cell.origin.x, .y = cell.origin.y + line_height - 1 }, .size = .{ .width = cell.size.width, .height = 1 } }, color(engine.render_state.colors.foreground));
        };
    }
    /// Builds one row at (0, 0). Consecutive equal non-default backgrounds become
    /// one quad; foreground glyphs/decorations follow all backgrounds in the row.
    pub fn buildRow(self: *Grid, a: std.mem.Allocator, y: usize, scale: f32) !ui.scene.Scene {
        var scene: ui.scene.Scene = .{};
        errdefer scene.deinit(a);
        const engine = self.engine;
        const bounds = g.Bounds{ .size = .{ .width = engine.cell_width * @as(f32, @floatFromInt(engine.columns)), .height = line_height } };
        var painter = cache.Painter{ .scene = &scene, .memory = a, .scale = scale, .clip = bounds };
        const cells = engine.render_state.row_data.items(.cells)[y].slice();
        const raws = cells.items(.raw);
        const styles = cells.items(.style);
        const graphemes = cells.items(.grapheme);
        const count = @min(raws.len, engine.columns);
        const background = color(engine.render_state.colors.background);
        var run_start: usize = 0;
        var run_color = background;
        for (raws[0..count], 0..) |raw, x| {
            const style = if (raw.style_id == 0) vt.Style{} else styles[x];
            const next = cellColors(engine, raw, style).background;
            if (std.meta.eql(next, run_color)) continue;
            if (!std.meta.eql(run_color, background)) try fill(&painter, self.cellBounds(bounds, run_start, 0, x - run_start), run_color);
            run_start = x;
            run_color = next;
        }
        if (!std.meta.eql(run_color, background)) try fill(&painter, self.cellBounds(bounds, run_start, 0, count - run_start), run_color);
        for (raws[0..count], 0..) |raw, x| {
            const style = if (raw.style_id == 0) vt.Style{} else styles[x];
            const cell = self.cellBounds(bounds, x, 0, if (raw.wide == .wide) 2 else 1);
            try self.paintCell(&painter, cell, raw, if (raw.hasGrapheme()) graphemes[x] else &.{}, style, cellColors(engine, raw, style).foreground);
        }
        return scene;
    }
    /// Serialize only inputs used by the painter into one reusable row buffer.
    /// No pointers, undefined style slots or struct padding enter the comparison.
    pub fn describeRow(self: *Grid, a: std.mem.Allocator, y: usize, bytes: *std.ArrayList(u8)) !void {
        // Fixed-layout record with no padding: one append per ordinary cell.
        const CellDescription = extern struct {
            codepoint: u32,
            flags: u16,
            wide: u8,
            grapheme: u8,
            foreground: [4]f32,
            background: [4]f32,
            extra_count: u32,
        };
        comptime {
            std.debug.assert(@sizeOf(CellDescription) == 44);
        }
        const cells = self.engine.render_state.row_data.items(.cells)[y].slice();
        const raws = cells.items(.raw);
        const styles = cells.items(.style);
        const graphemes = cells.items(.grapheme);
        const count = @min(raws.len, self.engine.columns);
        try bytes.ensureUnusedCapacity(a, count * @sizeOf(CellDescription));
        for (raws[0..count], 0..) |raw, x| {
            const style = if (raw.style_id == 0) vt.Style{} else styles[x];
            const colors = cellColors(self.engine, raw, style);
            const extra: []const u21 = if (raw.hasGrapheme()) graphemes[x] else &.{};
            const description = CellDescription{ .codepoint = raw.codepoint(), .flags = @bitCast(style.flags), .wide = @intFromEnum(raw.wide), .grapheme = @intFromBool(raw.hasGrapheme()), .foreground = .{ colors.foreground.r, colors.foreground.g, colors.foreground.b, colors.foreground.a }, .background = .{ colors.background.r, colors.background.g, colors.background.b, colors.background.a }, .extra_count = @intCast(extra.len) };
            try bytes.appendSlice(a, std.mem.asBytes(&description));
            for (extra) |point| {
                const value: u32 = point;
                try bytes.appendSlice(a, std.mem.asBytes(&value));
            }
        }
    }
    fn cellBounds(self: *const Grid, bounds: g.Bounds, x: usize, y: usize, span: usize) g.Bounds {
        return .{ .origin = .{ .x = bounds.origin.x + @as(f32, @floatFromInt(x)) * self.engine.cell_width, .y = bounds.origin.y + @as(f32, @floatFromInt(y)) * line_height }, .size = .{ .width = self.engine.cell_width * @as(f32, @floatFromInt(span)), .height = line_height } };
    }
    fn paintLine(self: *const Grid, f: anytype, cell: g.Bounds, line: *ui.LineLayout, foreground: g.Color) !void {
        for (line.runs) |run| for (run.glyphs) |glyph| {
            try f.scene.glyph(f.allocator(), .{ .system = self.engine.fonts, .font_id = run.font_id, .glyph_id = glyph.id, .font_size = font_size, .position = .{ .x = cell.origin.x + glyph.position.x, .y = cell.origin.y + self.engine.baseline + glyph.position.y }, .color = foreground, .clip = cell.intersect(f.clip) });
        };
    }
    fn paintCell(self: *const Grid, f: anytype, cell: g.Bounds, raw: vt.Cell, extra: []const u21, style: vt.Style, foreground: g.Color) !void {
        if (raw.wide == .spacer_tail or raw.wide == .spacer_head or style.flags.invisible) return;
        const cp = raw.codepoint();
        if (cp != 0 and cp != ' ') {
            if (!raw.hasGrapheme() and boxes.lookup(cp) != null) {
                try boxes.paint(f, cell, boxes.lookup(cp).?, foreground);
            } else {
                const index: usize = (if (style.flags.bold) @as(usize, 1) else 0) | (if (style.flags.italic) @as(usize, 2) else 0);
                const line = try self.engine.shapes.get(self.engine.fonts, self.engine.font_ids, font_size, index, cp, extra);
                try self.paintLine(f, cell, line, foreground);
            }
        }
        if (style.flags.underline != .none) try fill(f, .{ .origin = .{ .x = cell.origin.x, .y = cell.origin.y + line_height - 2 }, .size = .{ .width = cell.size.width, .height = 1 } }, foreground);
        if (style.flags.strikethrough) try fill(f, .{ .origin = .{ .x = cell.origin.x, .y = cell.origin.y + line_height / 2 }, .size = .{ .width = cell.size.width, .height = 1 } }, foreground);
        if (style.flags.overline) try fill(f, .{ .origin = cell.origin, .size = .{ .width = cell.size.width, .height = 1 } }, foreground);
    }
    fn paintCursor(self: *const Grid, f: *ui.Frame, bounds: g.Bounds) !void {
        const state = &self.engine.render_state;
        if (!state.cursor.visible) return;
        const cursor = state.cursor.viewport orelse return;
        const x: usize = if (cursor.wide_tail and cursor.x > 0) cursor.x - 1 else cursor.x;
        const rows = state.row_data.items(.cells);
        if (cursor.y >= rows.len) return;
        const cells = rows[cursor.y].slice();
        const raws = cells.items(.raw);
        if (x >= raws.len) return;
        const raw = raws[x];
        const cell = self.cellBounds(bounds, x, cursor.y, if (raw.wide == .wide) 2 else 1);
        const cursor_color = color(state.colors.cursor orelse state.colors.foreground);
        const visual = if (self.engine.focused) state.cursor.visual_style else .block_hollow;
        switch (visual) {
            .block => {
                try fill(f, cell, cursor_color);
                const style = if (raw.style_id == 0) vt.Style{} else cells.items(.style)[x];
                try self.paintCell(f, cell, raw, if (raw.hasGrapheme()) cells.items(.grapheme)[x] else &.{}, style, cellColors(self.engine, raw, style).background);
            },
            .bar => try fill(f, .{ .origin = cell.origin, .size = .{ .width = 2 / f.scale, .height = line_height } }, cursor_color),
            .underline => try fill(f, .{ .origin = .{ .x = cell.origin.x, .y = cell.origin.y + line_height - 1 / f.scale }, .size = .{ .width = cell.size.width, .height = 1 / f.scale } }, cursor_color),
            .block_hollow => try f.scene.border(f.allocator(), .{ .bounds = cell, .widths = .all(1 / f.scale), .color = cursor_color, .clip = f.clip }),
        }
    }
};
fn fill(f: anytype, bounds: g.Bounds, value: g.Color) !void {
    try f.scene.quad(f.allocator(), .{ .bounds = bounds, .color = value, .clip = f.clip });
}
fn cellColors(engine: *const Engine, raw: vt.Cell, style: vt.Style) struct { foreground: g.Color, background: g.Color } {
    var fg = color(style.fg(.{ .default = engine.render_state.colors.foreground, .palette = &engine.render_state.colors.palette }));
    var bg = color(style.bg(&raw, &engine.render_state.colors.palette) orelse engine.render_state.colors.background);
    if (style.flags.inverse) std.mem.swap(g.Color, &fg, &bg);
    if (style.flags.faint) {
        fg.r *= 0.5;
        fg.g *= 0.5;
        fg.b *= 0.5;
    }
    return .{ .foreground = fg, .background = bg };
}
/// VT colors are sRGB; zigui's scene colors are linear RGBA.
pub fn color(rgb: anytype) g.Color {
    return .{ .r = linear(rgb.r), .g = linear(rgb.g), .b = linear(rgb.b) };
}
const linear_colors: [256]f32 = blk: {
    @setEvalBranchQuota(100000);
    var result: [256]f32 = undefined;
    for (&result, 0..) |*value, i| {
        const x = @as(f32, @floatFromInt(i)) / 255;
        value.* = if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
    }
    break :blk result;
};
fn linear(value: u8) f32 {
    return linear_colors[value];
}

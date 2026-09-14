const std = @import("std");
const ui = @import("zigui");
const terminal = @import("model.zig");
const pty = @import("pty.zig");
const macos = @import("macos.zig");
const ContentWindow = ui.WindowWithRenderer(ui.platform.SurfaceRenderer);

/// Example-local host connects PTY events, reactive entities and native callbacks.
/// Platform/App APIs remain UI-thread-only; WakeBridge marshals worker output here.
const Host = struct {
    allocator: std.mem.Allocator,
    app: ui.App,
    platform: ?ui.Platform = null,
    surface: ?ui.PlatformWindow = null,
    window: ?ContentWindow = null,
    model: ?ui.Entity(terminal.Model) = null,
    wake: macos.WakeBridge,
    drawing: bool = false,
    stopped: bool = false,
    eof: bool = false,
    failure: ?anyerror = null,
    frames: usize = 0,
    last_title: []const u8 = "",

    fn init(self: *Host, a: std.mem.Allocator, io: std.Io, command: []const []const u8) !void {
        self.* = .{ .allocator = a, .app = .init(a), .wake = .{ .context = self, .deliver = onOutput } };
        errdefer self.deinit();
        self.platform = try ui.Platform.init(a);
        self.app.setTextSystem(self.platform.?.textSystem());
        self.app.wakeup = .{ .context = &self.platform.?, .schedule = ui.Platform.schedule };
        self.surface = try self.platform.?.openWindow(.{ .title = "zigui terminal", .size = .{ .width = 960, .height = 520 } });
        const terminal_engine = try terminal.Engine.create(a, io, self.app.text_system.?);
        self.model = self.app.create(terminal.Model{ .engine = terminal_engine }) catch |err| {
            terminal_engine.destroy();
            return err;
        };
        const metrics = self.surface.?.metrics();
        try self.app.updateWith(self.model.?, metrics, terminal.Model.resize);
        self.window = try ContentWindow.initWithRenderer(&self.app, self.model.?, metrics.size, metrics.scale, .{ .surface = self.surface.? });
        self.surface.?.setCallbacks(.{ .context = self, .request_frame = requestFrame, .resize = resize, .input = inputEvent, .focus = focus, .close = close });
        if (self.failure) |err| return err;
        self.surface.?.setTextInputHandler(.{ .context = self, .selected_range = selectedRange, .marked_range = markedRange, .text_for_range = textForRange, .bounds_for_range = boundsForRange, .character_index = characterIndex });
        terminal_engine.pty = try pty.Pty.spawn(a, command, .{ .context = &self.wake, .notify = macos.WakeBridge.notify });
        try self.app.updateWith(self.model.?, metrics, terminal.Model.resize);
        self.surface.?.requestFrame();
    }
    fn engine(self: *Host) *terminal.Engine {
        return (self.app.read(self.model.?) catch unreachable).engine;
    }
    fn stop(self: *Host) void {
        if (self.stopped) return;
        self.stopped = true;
        if (self.surface) |surface| {
            surface.setCallbacks(null);
            surface.setTextInputHandler(null);
        }
        self.wake.active = false;
        if (self.model != null) if (self.engine().pty) |process| process.shutdown();
        self.wake.detachAndDrain();
    }
    fn deinit(self: *Host) void {
        self.stop();
        if (self.window) |*window| window.deinit();
        self.app.wakeup = null;
        self.app.deinit();
        if (self.surface) |surface| surface.deinit();
        if (self.platform) |platform| platform.deinit();
        self.allocator.free(self.last_title);
    }
    fn fail(self: *Host, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        if (self.platform) |platform| platform.quit();
    }
    fn cast(ptr: *anyopaque) *Host {
        return @ptrCast(@alignCast(ptr));
    }
    fn consume(self: *Host) !void {
        if (self.stopped or self.drawing) return;
        const process = self.engine().pty orelse return;
        const output = try process.drain(self.allocator);
        defer self.allocator.free(output.bytes);
        if (output.failure) |err| return err;
        if (output.bytes.len > 0) try self.app.updateWith(self.model.?, output.bytes, terminal.Model.output);
        if (output.eof and !self.eof) {
            self.eof = true;
            self.window.?.invalidate();
        }
    }
    fn onOutput(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.consume() catch |err| self.fail(err);
        if (!self.stopped) self.platform.?.wake();
    }
    fn requestFrame(ptr: *anyopaque, options: ui.platform.RequestFrameOptions) void {
        const self = cast(ptr);
        self.draw(options) catch |err| switch (err) {
            // Minimized/unavailable surfaces and an intervening native resize are
            // retryable. The framework keeps the previous frame and dirty state.
            error.SurfaceUnavailable, error.SurfaceChangedDuringFrame, error.DrawableSizeMismatch, error.FrameDuringUpdate => {
                if (self.eof) self.platform.?.quit();
            },
            else => self.fail(err),
        };
    }
    fn draw(self: *Host, options: ui.platform.RequestFrameOptions) !void {
        if (self.stopped or self.drawing) return;
        if (self.failure != null) {
            self.platform.?.quit();
            return;
        }
        try self.consume();
        self.drawing = true;
        defer self.drawing = false;
        if (options.force_render) self.window.?.invalidate();
        if (try self.window.?.drawIfNeeded()) self.frames += 1;
        const title = self.engine().terminal.getTitle() orelse "zigui terminal";
        if (!std.mem.eql(u8, title, self.last_title)) {
            const copy = try self.allocator.dupe(u8, title);
            self.allocator.free(self.last_title);
            self.last_title = copy;
            self.surface.?.setTitle(title);
        }
        // Present the final output before returning from the loop on shell exit.
        if (self.eof) self.platform.?.quit();
    }
    fn resize(ptr: *anyopaque, metrics: ui.platform.Metrics) void {
        const self = cast(ptr);
        if (self.stopped) return;
        self.window.?.resize(metrics.size, metrics.scale) catch |err| {
            self.fail(err);
            return;
        };
        self.app.updateWith(self.model.?, metrics, terminal.Model.resize) catch |err| self.fail(err);
    }
    fn focus(ptr: *anyopaque, focused: bool) void {
        const self = cast(ptr);
        if (self.stopped) return;
        self.app.updateWith(self.model.?, focused, terminal.Model.focus) catch |err| {
            if (err != error.PtyClosed) self.fail(err);
        };
    }
    fn close(ptr: *anyopaque) void {
        cast(ptr).platform.?.quit();
    }
    fn inputEvent(ptr: *anyopaque, event: ui.input.PlatformInput) ui.input.DispatchEventResult {
        const self = cast(ptr);
        if (self.stopped) return .{};
        if (event == .key_down and event.key_down.modifiers.command) {
            if (std.mem.eql(u8, event.key_down.key, "q")) {
                self.platform.?.quit();
                return .{ .handled = true };
            }
            if (std.mem.eql(u8, event.key_down.key, "v")) {
                self.pasteClipboard() catch |err| {
                    if (err != error.PtyClosed) self.fail(err);
                };
                return .{ .handled = true };
            }
        }
        var handled = false;
        self.app.updateWith(self.model.?, terminal.Model.Input{ .event = event, .handled = &handled }, terminal.Model.input) catch |err| {
            if (err != error.PtyClosed) self.fail(err);
            return .{ .handled = true };
        };
        return .{ .handled = handled };
    }
    fn pasteClipboard(self: *Host) !void {
        const bytes = (try macos.clipboard(self.allocator)) orelse return;
        defer self.allocator.free(bytes);
        try self.app.updateWith(self.model.?, bytes, terminal.Model.paste);
    }
    fn selectedRange(ptr: *anyopaque) ?ui.input.TextRange {
        return cast(ptr).engine().preedit_selection;
    }
    fn markedRange(ptr: *anyopaque) ?ui.input.TextRange {
        const bytes = cast(ptr).engine().preedit;
        if (bytes.len == 0) return null;
        var iterator = (std.unicode.Utf8View.init(bytes) catch return null).iterator();
        var len: usize = 0;
        while (iterator.nextCodepoint()) |cp| len += if (cp > 0xffff) @as(usize, 2) else 1;
        return .{ .location = 0, .length = len };
    }
    fn textForRange(ptr: *anyopaque, range: ui.input.TextRange) ?[]const u8 {
        const bytes = cast(ptr).engine().preedit;
        const end = std.math.add(usize, range.location, range.length) catch return null;
        const start_byte = utf16Offset(bytes, range.location) orelse return null;
        const end_byte = utf16Offset(bytes, end) orelse return null;
        return bytes[start_byte..end_byte];
    }
    fn boundsForRange(ptr: *anyopaque, _: ui.input.TextRange) ?ui.geometry.Bounds {
        return cast(ptr).engine().cursorBounds();
    }
    fn characterIndex(_: *anyopaque, _: ui.geometry.Point) ?usize {
        return 0;
    }
};
fn utf16Offset(bytes: []const u8, offset: usize) ?usize {
    var byte: usize = 0;
    var utf16: usize = 0;
    while (byte < bytes.len) {
        if (utf16 == offset) return byte;
        const len = std.unicode.utf8ByteSequenceLength(bytes[byte]) catch return null;
        const cp = std.unicode.utf8Decode(bytes[byte..][0..len]) catch return null;
        utf16 += if (cp > 0xffff) @as(usize, 2) else 1;
        byte += len;
    }
    return if (utf16 == offset) byte else null;
}

pub const smoke_script = "printf '\x1b[2J\x1b[HTerminal smoke\\r\\n\x1b[31mred\x1b[0m \x1b[48;5;236mbackground\x1b[0m\\r\\n┌──┐ é 界 🐳\\r\\n'; IFS= read -r line; printf 'echo:%s\\r\\nTERM:%s\\r\\n' \"$line\" \"$TERM\"; stty size";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const smoke = args.len == 2 and std.mem.eql(u8, args[1], "--smoke");
    const command: []const []const u8 = if (smoke) &.{ "/bin/sh", "-c", smoke_script } else blk: {
        const command = try init.arena.allocator().alloc([]const u8, args.len - 1);
        for (args[1..], 0..) |arg, i| command[i] = arg;
        break :blk command;
    };
    const exit_code: u8 = blk: {
        var host: Host = undefined;
        try host.init(std.heap.c_allocator, init.io, command);
        defer host.deinit();
        if (smoke) try host.engine().pty.?.write("ping\n");
        host.platform.?.run();
        host.stop();
        if (host.failure) |err| return err;
        const engine = host.engine();
        const status = engine.pty.?.exit_status orelse 0;
        const code: u8 = if (status & 0x7f == 0) @intCast((status >> 8) & 0xff) else @intCast(128 + (status & 0x7f));
        if (smoke) {
            if (!host.eof or host.frames == 0 or code != 0) return error.SmokeFailed;
            const contents = try viewportText(host.allocator, engine);
            defer host.allocator.free(contents);
            if (std.mem.indexOf(u8, contents, "Terminal smoke") == null or std.mem.indexOf(u8, contents, "echo:ping") == null or std.mem.indexOf(u8, contents, "TERM:xterm-256color") == null) return error.SmokeOutputMissing;
            if (std.mem.indexOf(u8, contents, "é 界 🐳") == null) return error.SmokeUnicodeMissing;
            const dimensions = try std.fmt.allocPrint(host.allocator, "{d} {d}", .{ engine.rows, engine.columns });
            defer host.allocator.free(dimensions);
            if (std.mem.indexOf(u8, contents, dimensions) == null) return error.SmokeResizeMissing;
            var glyphs: usize = 0;
            for (host.window.?.inspect().?.scene) |primitive| if (primitive == .glyph) {
                glyphs += 1;
            };
            if (glyphs == 0) return error.SmokeGlyphsMissing;
            std.debug.print("terminal smoke passed: PTY input/output, ANSI/Unicode, {d}x{d} grid, {d} glyphs, child reaped; {d} row builds, {d} row reuses, {d} shape misses\n", .{
                engine.columns, engine.rows, glyphs, engine.row_cache.rebuilt, engine.row_cache.reused, engine.shapes.misses,
            });
        }
        break :blk if (host.eof) code else 0;
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

/// Diagnostic text used by the finite smoke run and example tests.
pub fn viewportText(a: std.mem.Allocator, engine: *const terminal.Engine) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    for (engine.render_state.row_data.items(.cells)) |row| {
        const cells = row.slice();
        for (cells.items(.raw), 0..) |raw, x| {
            if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
            var buffer: [4]u8 = undefined;
            const cp = raw.codepoint();
            const len = try std.unicode.utf8Encode(if (cp == 0) ' ' else cp, &buffer);
            try text.appendSlice(a, buffer[0..len]);
            if (raw.hasGrapheme()) for (cells.items(.grapheme)[x]) |extra| {
                const n = try std.unicode.utf8Encode(extra, &buffer);
                try text.appendSlice(a, buffer[0..n]);
            };
        }
        try text.append(a, '\n');
    }
    return text.toOwnedSlice(a);
}

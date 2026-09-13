const std = @import("std");
const system = @import("text_system.zig");
const Frame = @import("frame.zig").Frame;
const element = @import("element.zig");
const layout = @import("layout.zig");
const g = @import("geometry.zig");

/// Text element configuration. Byte runs override inherited font/color; wrapping
/// uses the measured Yoga width, while explicit newlines always create new lines.
pub const Options = struct {
    style: system.TextStyleRefinement = .{},
    layout_style: layout.Style = .{},
    runs: []const system.TextRun = &.{},
    wrap: bool = false,
    id: ?u64 = null,
};

pub fn create(f: *Frame, value: []const u8, options: Options) !element.AnyElement {
    var owned = options;
    const runs = try f.allocator().dupe(system.TextRun, options.runs);
    for (runs) |*run| if (run.font) |*font| {
        font.family = try f.allocator().dupe(u8, font.family);
    };
    owned.runs = runs;
    if (owned.style.font) |*font| font.family = try f.allocator().dupe(u8, font.family);
    return f.element(Text{ .value = try f.allocator().dupe(u8, value), .options = owned });
}

/// A shaped-text leaf in the normal request-layout/prepaint/paint lifecycle.
/// Its temporary measurement state owns no persistent scene data; paint emits
/// retained, platform-independent glyph descriptors into the frame's scene.
pub const Text = struct {
    pub const RequestLayoutState = ?*Measurement;
    pub const PrepaintState = ?*system.TextLayout;
    value: []const u8,
    options: Options,

    pub fn requestLayout(self: *Text, f: *Frame) !element.LayoutRequest(RequestLayoutState) {
        if (self.options.layout_style.hidden) return .{ .id = try f.layout.request(self.options.layout_style, &.{}), .state = null };
        const service = f.text_system orelse return error.TextSystemUnavailable;
        const style = f.text_style.refine(self.options.style);
        try system.validateSize(style.font_size);
        if (style.line_height) |height| try system.validateSize(height);
        if (self.options.runs.len > 0) try system.validateRuns(self.value, self.options.runs);
        var fonts: std.ArrayList(system.FontRun) = .empty;
        if (self.options.runs.len == 0) {
            try fonts.append(f.allocator(), .{ .len = self.value.len, .font_id = try service.fontId(style.font) });
        } else for (self.options.runs) |run| {
            const font_id = try service.fontId(run.font orelse style.font);
            // Color-only span boundaries do not change shaping or its cache key.
            if (fonts.items.len > 0 and fonts.items[fonts.items.len - 1].font_id == font_id) {
                fonts.items[fonts.items.len - 1].len = try std.math.add(usize, fonts.items[fonts.items.len - 1].len, run.len);
            } else try fonts.append(f.allocator(), .{ .len = run.len, .font_id = font_id });
        }
        try system.validateRuns(self.value, fonts.items);
        const measurement = try f.allocator().create(Measurement);
        measurement.* = .{ .frame = f, .service = service, .text = self.value, .fonts = fonts.items, .style = style, .wrap = self.options.wrap, .padding = self.options.layout_style.padding };
        const id = try f.layout.request(self.options.layout_style, &.{});
        layout.c.YGNodeSetContext(id, measurement);
        layout.c.YGNodeSetMeasureFunc(id, Measurement.measure);
        layout.c.YGNodeSetBaselineFunc(id, Measurement.baseline);
        return .{ .id = id, .state = measurement };
    }
    pub fn prepaint(self: *Text, f: *Frame, bounds: g.Bounds, measurement: *RequestLayoutState) !PrepaintState {
        const measured = measurement.* orelse return null;
        if (self.options.id) |id| try f.hitbox(id, bounds);
        return try measured.resolve(if (self.options.wrap) @max(0, bounds.size.width - measured.padding.left - measured.padding.right) else null);
    }
    pub fn paint(self: *Text, f: *Frame, bounds: g.Bounds, measurement: *RequestLayoutState, shaped: *PrepaintState) !void {
        const measured = measurement.* orelse return;
        const text_layout = shaped.* orelse return;
        const clip = if (self.options.layout_style.clip) f.clip.intersect(bounds) else f.clip;
        if (self.options.layout_style.background) |color| try f.scene.quad(f.allocator(), .{ .bounds = bounds, .clip = clip, .color = color });
        for (text_layout.lines.items) |line| for (line.layout.runs) |run| for (run.glyphs) |glyph| {
            var color = measured.style.color;
            var start: usize = 0;
            for (self.options.runs) |text_run| {
                if (line.byte_start + glyph.index < start + text_run.len) {
                    color = text_run.color orelse color;
                    break;
                }
                start += text_run.len;
            }
            try f.scene.glyph(f.allocator(), .{ .system = measured.service, .font_id = run.font_id, .glyph_id = glyph.id, .font_size = measured.style.font_size, .position = .{ .x = bounds.origin.x + measured.padding.left + glyph.position.x, .y = bounds.origin.y + measured.padding.top + line.baseline + glyph.position.y }, .color = color, .clip = clip });
        };
    }
};

/// Stable frame-owned bridge for Yoga's C callbacks. Fallible layout work records
/// errors on Layout so the frame aborts before submitting incomplete text.
const Measurement = struct {
    frame: *Frame,
    service: *system.TextSystem,
    text: []const u8,
    fonts: []const system.FontRun,
    style: system.TextStyle,
    wrap: bool,
    padding: layout.Edges,
    last_width: ?f32 = null,
    last_layout: ?*system.TextLayout = null,
    fn resolve(self: *Measurement, width: ?f32) !*system.TextLayout {
        if (self.last_layout) |previous| if (self.last_width == width) return previous;
        const result = try self.service.layoutText(self.frame.app.allocator, self.text, self.style.font_size, self.fonts, width, self.style.line_height);
        errdefer result.destroy();
        try self.frame.text_layouts.append(self.frame.allocator(), result);
        self.last_width = width;
        self.last_layout = result;
        return result;
    }
    fn fromNode(node: layout.c.YGNodeConstRef) *Measurement {
        return @ptrCast(@alignCast(layout.c.YGNodeGetContext(node).?));
    }
    fn measure(node: layout.c.YGNodeConstRef, width: f32, width_mode: layout.c.YGMeasureMode, height: f32, height_mode: layout.c.YGMeasureMode) callconv(.c) layout.c.YGSize {
        const self = fromNode(node);
        const constraint: ?f32 = if (self.wrap and width_mode != layout.c.YGMeasureModeUndefined) @max(0, width) else null;
        const result = self.resolve(constraint) catch |err| {
            self.frame.layout.measure_error = err;
            return .{ .width = 0, .height = 0 };
        };
        return .{ .width = constrain(result.size.width, width, width_mode), .height = constrain(result.size.height, height, height_mode) };
    }
    fn baseline(node: layout.c.YGNodeConstRef, width: f32, _: f32) callconv(.c) f32 {
        const self = fromNode(node);
        const result = self.resolve(if (self.wrap) @max(0, width - self.padding.left - self.padding.right) else null) catch |err| {
            self.frame.layout.measure_error = err;
            return 0;
        };
        return self.padding.top + result.lines.items[0].baseline;
    }
    fn constrain(value: f32, available: f32, mode: layout.c.YGMeasureMode) f32 {
        return switch (mode) {
            layout.c.YGMeasureModeExactly => available,
            layout.c.YGMeasureModeAtMost => @min(value, available),
            else => value,
        };
    }
};

const std = @import("std");
const text = @import("../text_system.zig");

/// Explicit test backend with synthetic monospace metrics and rectangular glyphs.
/// Production platforms supply their own shaper instead of using these fixtures.
const Stub = struct {
    allocator: std.mem.Allocator,
    fonts: std.ArrayList(text.Font) = .empty,
    fn cast(ptr: *anyopaque) *Stub {
        return @ptrCast(@alignCast(ptr));
    }
    fn deinit(ptr: *anyopaque) void {
        const self = cast(ptr);
        for (self.fonts.items) |font| self.allocator.free(font.family);
        self.fonts.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    fn fontId(ptr: *anyopaque, font: text.Font) !text.FontId {
        const self = cast(ptr);
        for (self.fonts.items, 0..) |existing, i| if (existing.eql(font)) return @enumFromInt(i);
        var owned = font;
        owned.family = try self.allocator.dupe(u8, font.family);
        errdefer self.allocator.free(owned.family);
        const id: text.FontId = @enumFromInt(@as(u32, @intCast(self.fonts.items.len)));
        try self.fonts.append(self.allocator, owned);
        return id;
    }
    fn metrics(ptr: *anyopaque, id: text.FontId) !text.FontMetrics {
        if (@intFromEnum(id) >= cast(ptr).fonts.items.len) return error.InvalidFontId;
        return .{ .units_per_em = 1000, .ascent = 800, .descent = 200, .leading = 0, .cap_height = 700, .x_height = 500 };
    }
    fn layoutLine(ptr: *anyopaque, a: std.mem.Allocator, bytes: []const u8, size: f32, runs: []const text.FontRun) !*text.LineLayout {
        const result = try text.LineLayout.create(a);
        errdefer result.release();
        result.ascent = size * 0.8;
        result.descent = size * 0.2;
        const memory = result.memory();
        var shaped: std.ArrayList(text.ShapedRun) = .empty;
        var carets: std.ArrayList(text.Caret) = .empty;
        var offset: usize = 0;
        var x: f32 = 0;
        for (runs) |run| {
            _ = try metrics(ptr, run.font_id);
            var glyphs: std.ArrayList(text.ShapedGlyph) = .empty;
            const end = offset + run.len;
            while (offset < end) {
                const len = try std.unicode.utf8ByteSequenceLength(bytes[offset]);
                const cp = try std.unicode.utf8Decode(bytes[offset..][0..len]);
                const combining = cp >= 0x300 and cp <= 0x36f;
                const advance: f32 = if (combining) 0 else if (cp == '\t') size * 2.4 else size * 0.6;
                if (!combining) try carets.append(memory, .{ .index = offset, .x = x });
                try glyphs.append(memory, .{ .id = cp, .position = .{ .x = x, .y = 0 }, .advance = advance, .index = offset });
                x += advance;
                offset += len;
            }
            try shaped.append(memory, .{ .font_id = run.font_id, .glyphs = glyphs.items });
        }
        try carets.append(memory, .{ .index = bytes.len, .x = x });
        result.runs = shaped.items;
        result.carets = carets.items;
        result.width = x;
        return result;
    }
    fn bounds(ptr: *anyopaque, params: text.RenderGlyphParams) !text.RasterBounds {
        _ = try metrics(ptr, params.font_id);
        if (params.glyph_id == ' ' or params.glyph_id == '\t') return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const size = params.font_size * params.scale;
        return .{ .x = 0, .y = -@as(i32, @intFromFloat(@ceil(size * 0.8))), .width = @intFromFloat(@ceil(size * 0.6)), .height = @intFromFloat(@ceil(size)) };
    }
    fn rasterize(_: *anyopaque, a: std.mem.Allocator, _: text.RenderGlyphParams, rect: text.RasterBounds) !text.RasterizedGlyph {
        const pixels = try a.alloc(u8, @as(usize, rect.width) * rect.height);
        @memset(pixels, 255);
        return .{ .bounds = rect, .format = .alpha8, .pixels = pixels };
    }
    const vtable: text.PlatformTextSystem.VTable = .{ .deinit = deinit, .font_id = fontId, .font_metrics = metrics, .layout_line = layoutLine, .glyph_raster_bounds = bounds, .rasterize_glyph = rasterize };
};
pub fn create(a: std.mem.Allocator) !text.PlatformTextSystem {
    const self = try a.create(Stub);
    self.* = .{ .allocator = a };
    return .{ .ptr = self, .vtable = &Stub.vtable };
}

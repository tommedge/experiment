const std = @import("std");
const g = @import("geometry.zig");
pub const stub = @import("text/stub.zig");

pub const FontId = enum(u32) { _ };
pub const GlyphId = u32;
pub const FontWeight = enum { normal, bold };
pub const FontStyle = enum { normal, italic };

/// Size-independent font request. The platform resolves a stable FontId; shaping
/// may return additional font IDs for fallback runs, as in GPUI.
pub const Font = struct {
    family: []const u8 = "Menlo",
    weight: FontWeight = .normal,
    style: FontStyle = .normal,
    pub fn eql(a: Font, b: Font) bool {
        return std.mem.eql(u8, a.family, b.family) and a.weight == b.weight and a.style == b.style;
    }
};
/// Font-space metrics. Multiply by font_size / units_per_em for logical pixels.
pub const FontMetrics = struct { units_per_em: f32, ascent: f32, descent: f32, leading: f32, cap_height: f32, x_height: f32 };
/// Consecutive UTF-8 byte range using one resolved font. Runs cover the whole line.
pub const FontRun = struct { len: usize, font_id: FontId };
/// Styled byte range; absent fields inherit the containing element's text style.
pub const TextRun = struct { len: usize, font: ?Font = null, color: ?g.Color = null };
/// Inherited text environment, independent of Yoga's box style.
pub const TextStyle = struct {
    font: Font = .{},
    font_size: f32 = 14,
    color: g.Color = .{ .r = 1, .g = 1, .b = 1 },
    line_height: ?f32 = null,
    pub fn refine(self: TextStyle, refinement: TextStyleRefinement) TextStyle {
        return .{ .font = refinement.font orelse self.font, .font_size = refinement.font_size orelse self.font_size, .color = refinement.color orelse self.color, .line_height = refinement.line_height orelse self.line_height };
    }
    pub fn eql(a: TextStyle, b: TextStyle) bool {
        return a.font.eql(b.font) and a.font_size == b.font_size and std.meta.eql(a.color, b.color) and a.line_height == b.line_height;
    }
};
/// Overrides applied by a Div or Text element within its traversal scope.
pub const TextStyleRefinement = struct { font: ?Font = null, font_size: ?f32 = null, color: ?g.Color = null, line_height: ?f32 = null };

/// A positioned glyph in logical pixels, relative to the line's baseline.
/// index identifies its source UTF-8 cluster; IDs belong to the containing run's font.
pub const ShapedGlyph = struct { id: GlyphId, position: g.Point, advance: f32, index: usize, is_emoji: bool = false };
/// Visual glyph sequence sharing the actual font selected by the shaper.
pub const ShapedRun = struct { font_id: FontId, glyphs: []const ShapedGlyph };
/// A grapheme-safe insertion point. Logical byte order can differ from visual x order.
pub const Caret = struct { index: usize, x: f32 };

/// Reference-counted shaping result with independent storage. It remains valid
/// after LRU eviction; it contains no platform objects or frame-arena pointers.
pub const LineLayout = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    references: usize = 1,
    text: []const u8 = "",
    font_size: f32 = 0,
    width: f32 = 0,
    ascent: f32 = 0,
    descent: f32 = 0,
    leading: f32 = 0,
    runs: []const ShapedRun = &.{},
    carets: []const Caret = &.{},
    font_runs: []const FontRun = &.{},
    pub fn create(a: std.mem.Allocator) !*LineLayout {
        const self = try a.create(LineLayout);
        self.* = .{ .allocator = a, .arena = .init(a) };
        return self;
    }
    pub fn memory(self: *LineLayout) std.mem.Allocator {
        return self.arena.allocator();
    }
    pub fn retain(self: *LineLayout) *LineLayout {
        self.references += 1;
        return self;
    }
    pub fn release(self: *LineLayout) void {
        self.references -= 1;
        if (self.references == 0) {
            self.arena.deinit();
            self.allocator.destroy(self);
        }
    }
    pub fn closestIndexForX(self: *const LineLayout, x: f32) usize {
        var best: usize = 0;
        var distance = std.math.inf(f32);
        for (self.carets) |caret| if (@abs(caret.x - x) < distance) {
            distance = @abs(caret.x - x);
            best = caret.index;
        };
        return best;
    }
    pub fn indexForX(self: *const LineLayout, x: f32) ?usize {
        return if (x < 0 or x >= self.width) null else self.closestIndexForX(x);
    }
    pub fn xForIndex(self: *const LineLayout, index: usize) f32 {
        for (self.carets) |caret| if (caret.index >= index) return caret.x;
        return if (self.carets.len == 0) 0 else self.carets[self.carets.len - 1].x;
    }
    fn prefixWidth(self: *const LineLayout, index: usize) f32 {
        var result: f32 = 0;
        for (self.runs) |run| for (run.glyphs) |glyph| {
            if (glyph.index < index) result += @abs(glyph.advance);
        };
        return result;
    }
};

/// Raster cache key. Subpixel coordinates are quarter-device-pixel phases, not
/// absolute positions, so the same glyph can be reused throughout a scene.
pub const RenderGlyphParams = struct { font_id: FontId, glyph_id: GlyphId, font_size: f32, scale: f32, subpixel: [2]u8 = .{ 0, 0 } };
/// Device-pixel bounds relative to a glyph's integer baseline, with y downward.
pub const RasterBounds = struct { x: i32, y: i32, width: u32, height: u32 };
pub const RasterFormat = enum { alpha8, rgba8 };
/// Owned top-to-bottom bitmap. RGBA data is premultiplied sRGB; alpha8 is coverage.
pub const RasterizedGlyph = struct {
    bounds: RasterBounds,
    format: RasterFormat,
    pixels: []u8,
    pub fn deinit(self: *RasterizedGlyph, a: std.mem.Allocator) void {
        a.free(self.pixels);
    }
};

/// Owning platform interface for font resolution, metrics, shaping and rasterization.
/// Implementations keep font IDs stable until deinit. All calls are UI-thread only.
pub const PlatformTextSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Platform-specific operations; returned lines/bitmaps own their allocations.
    pub const VTable = struct {
        deinit: *const fn (*anyopaque) void,
        font_id: *const fn (*anyopaque, Font) anyerror!FontId,
        font_metrics: *const fn (*anyopaque, FontId) anyerror!FontMetrics,
        layout_line: *const fn (*anyopaque, std.mem.Allocator, []const u8, f32, []const FontRun) anyerror!*LineLayout,
        glyph_raster_bounds: *const fn (*anyopaque, RenderGlyphParams) anyerror!RasterBounds,
        rasterize_glyph: *const fn (*anyopaque, std.mem.Allocator, RenderGlyphParams, RasterBounds) anyerror!RasterizedGlyph,
    };
    pub fn deinit(self: PlatformTextSystem) void {
        self.vtable.deinit(self.ptr);
    }
};

/// One shaped line placed within a multiline text layout. byte_start indexes the
/// original text, while the line's glyph/caret indexes are relative to that line.
pub const PositionedLine = struct { layout: *LineLayout, byte_start: usize, top: f32, baseline: f32, height: f32 };
/// Owned measurement/painting result. Frames release it after painting; cached
/// views retain only the resulting glyph primitives, not this temporary layout.
pub const TextLayout = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    lines: std.ArrayList(PositionedLine) = .empty,
    size: g.Size = .{ .width = 0, .height = 0 },
    pub fn destroy(self: *TextLayout) void {
        for (self.lines.items) |line| line.layout.release();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

/// Shared, reference-counted text service with a bounded LRU shaping cache.
/// Platforms and Apps retain it, as do glyph scenes, so cached output can outlive
/// the frame that shaped it. GPU atlas ownership remains with the renderer.
pub const TextSystem = struct {
    allocator: std.mem.Allocator,
    platform: PlatformTextSystem,
    references: usize = 1,
    generation: u64 = 0,
    clock: u64 = 0,
    cache: std.ArrayList(CacheEntry) = .empty,
    cache_capacity: usize = 128,
    cache_hits: usize = 0,
    shape_calls: usize = 0,
    /// Cache owns one reference; callers independently retain the same immutable line.
    const CacheEntry = struct { line: *LineLayout, used: u64 };
    pub fn create(a: std.mem.Allocator, platform: PlatformTextSystem) !*TextSystem {
        const self = try a.create(TextSystem);
        self.* = .{ .allocator = a, .platform = platform };
        return self;
    }
    pub fn retain(self: *TextSystem) *TextSystem {
        self.references += 1;
        return self;
    }
    pub fn release(self: *TextSystem) void {
        self.references -= 1;
        if (self.references != 0) return;
        self.clearCache();
        self.cache.deinit(self.allocator);
        self.platform.deinit();
        self.allocator.destroy(self);
    }
    pub fn clearCache(self: *TextSystem) void {
        for (self.cache.items) |entry| entry.line.release();
        self.cache.clearRetainingCapacity();
        self.generation += 1;
    }
    pub fn fontId(self: *TextSystem, font: Font) !FontId {
        if (font.family.len == 0 or !std.unicode.utf8ValidateSlice(font.family)) return error.InvalidFont;
        return self.platform.vtable.font_id(self.platform.ptr, font);
    }
    pub fn fontMetrics(self: *TextSystem, id: FontId) !FontMetrics {
        return self.platform.vtable.font_metrics(self.platform.ptr, id);
    }
    pub fn shapeLine(self: *TextSystem, text: []const u8, font_size: f32, runs: []const FontRun) !*LineLayout {
        try validateRuns(text, runs);
        try validateSize(font_size);
        if (std.mem.indexOfScalar(u8, text, '\n') != null or std.mem.indexOfScalar(u8, text, '\r') != null) return error.ExpectedSingleLine;
        self.clock += 1;
        for (self.cache.items) |*entry| {
            const line = entry.line;
            if (line.font_size == font_size and std.mem.eql(u8, line.text, text) and equalRuns(line.font_runs, runs)) {
                entry.used = self.clock;
                self.cache_hits += 1;
                return line.retain();
            }
        }
        const line = try self.platform.vtable.layout_line(self.platform.ptr, self.allocator, text, font_size, runs);
        errdefer line.release();
        self.shape_calls += 1;
        line.text = try line.memory().dupe(u8, text);
        line.font_size = font_size;
        line.font_runs = try line.memory().dupe(FontRun, runs);
        if (self.cache_capacity > 0) {
            while (self.cache.items.len >= self.cache_capacity) {
                var oldest: usize = 0;
                for (self.cache.items, 0..) |entry, i| if (entry.used < self.cache.items[oldest].used) {
                    oldest = i;
                };
                const removed = self.cache.orderedRemove(oldest);
                removed.line.release();
            }
            try self.cache.append(self.allocator, .{ .line = line, .used = self.clock });
            _ = line.retain();
        }
        return line;
    }
    pub fn rasterizeGlyph(self: *TextSystem, a: std.mem.Allocator, params: RenderGlyphParams) !RasterizedGlyph {
        try validateSize(params.font_size);
        try validateSize(params.scale);
        if (params.subpixel[0] >= 4 or params.subpixel[1] >= 4 or params.font_size * params.scale > 4096) return error.InvalidGlyphSize;
        const bounds = try self.platform.vtable.glyph_raster_bounds(self.platform.ptr, params);
        return self.platform.vtable.rasterize_glyph(self.platform.ptr, a, params, bounds);
    }
    pub fn layoutText(self: *TextSystem, a: std.mem.Allocator, text: []const u8, font_size: f32, runs: []const FontRun, wrap_width: ?f32, line_height: ?f32) !*TextLayout {
        try validateRuns(text, runs);
        try validateSize(font_size);
        if (line_height) |height| try validateSize(height);
        if (wrap_width) |width| if (!std.math.isFinite(width) or width < 0) return error.InvalidSize;
        const result = try a.create(TextLayout);
        result.* = .{ .allocator = a, .arena = .init(a) };
        errdefer result.destroy();
        const memory = result.arena.allocator();
        var start: usize = 0;
        while (true) {
            var end = start;
            while (end < text.len and text[end] != '\n' and text[end] != '\r') : (end += 1) {}
            var offset = start;
            while (true) {
                const remaining_runs = try sliceRuns(memory, runs, offset, end);
                var line = try self.shapeLine(text[offset..end], font_size, remaining_runs);
                var cut = end - offset;
                errdefer line.release();
                if (wrap_width) |width| if (line.width > width and cut > 0) {
                    var fitting: usize = 0;
                    var word: usize = 0;
                    var first: usize = cut;
                    for (line.carets) |caret| {
                        if (caret.index == 0) continue;
                        first = @min(first, caret.index);
                        if (line.prefixWidth(caret.index) > width) break;
                        fitting = caret.index;
                        const last = text[offset + caret.index - 1];
                        if (last == ' ' or last == '\t' or last == '-') word = caret.index;
                    }
                    cut = if (word > 0) word else if (fitting > 0) fitting else first;
                    // Reshape each visual line so joining and kerning reflect the
                    // actual break. Shrink again if contextual shaping widened it.
                    const unwrapped = line.retain();
                    defer unwrapped.release();
                    const shaped = try self.shapeLine(text[offset..][0..cut], font_size, try sliceRuns(memory, runs, offset, offset + cut));
                    line.release();
                    line = shaped;
                    while (line.width > width and cut > first) {
                        var previous: usize = first;
                        for (unwrapped.carets) |caret| if (caret.index > 0 and caret.index < cut) {
                            previous = caret.index;
                        };
                        cut = previous;
                        const replacement = try self.shapeLine(text[offset..][0..cut], font_size, try sliceRuns(memory, runs, offset, offset + cut));
                        line.release();
                        line = replacement;
                    }
                };
                const height = line_height orelse @max(1, line.ascent + line.descent + line.leading);
                try result.lines.append(memory, .{ .layout = line, .byte_start = offset, .top = result.size.height, .baseline = result.size.height + (height - line.ascent - line.descent) / 2 + line.ascent, .height = height });
                result.size.width = @max(result.size.width, line.width);
                result.size.height += height;
                offset += cut;
                if (offset >= end) break;
            }
            if (end == text.len) break;
            start = end + 1;
            if (text[end] == '\r' and start < text.len and text[start] == '\n') start += 1;
        }
        return result;
    }
};

pub fn validateSize(size: f32) !void {
    if (!std.math.isFinite(size) or size <= 0) return error.InvalidSize;
}
fn equalRuns(a: []const FontRun, b: []const FontRun) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}
pub fn validateRuns(text: []const u8, runs: anytype) !void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (runs.len == 0) return error.MissingFontRuns;
    var offset: usize = 0;
    for (runs) |run| {
        if (run.len > text.len - offset) return error.InvalidTextRuns;
        offset += run.len;
        if (offset < text.len and text[offset] & 0xc0 == 0x80) return error.InvalidTextRuns;
    }
    if (offset != text.len) return error.InvalidTextRuns;
}
fn sliceRuns(a: std.mem.Allocator, runs: []const FontRun, start: usize, end: usize) ![]const FontRun {
    var result: std.ArrayList(FontRun) = .empty;
    var offset: usize = 0;
    for (runs) |run| {
        const next = offset + run.len;
        if (next > start and offset < end) try result.append(a, .{ .len = @min(next, end) - @max(offset, start), .font_id = run.font_id });
        offset = next;
    }
    if (result.items.len == 0) {
        var font = runs[runs.len - 1].font_id;
        var run_end: usize = 0;
        for (runs) |run| {
            run_end += run.len;
            if (start < run_end) {
                font = run.font_id;
                break;
            }
        }
        try result.append(a, .{ .len = 0, .font_id = font });
    }
    return result.items;
}

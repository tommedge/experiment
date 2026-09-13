const std = @import("std");
const text = @import("../../text_system.zig");

/// CoreText/CoreGraphics C ABI, accessed directly from Zig as in ../editor.
/// Native handles stay behind PlatformTextSystem; no Objective-C source is used.
const native = struct {
    const Ref = ?*anyopaque;
    const Point = extern struct { x: f64, y: f64 };
    const Size = extern struct { width: f64, height: f64 };
    const Rect = extern struct { origin: Point, size: Size };
    const Range = extern struct { location: isize, length: isize };
    extern var kCTFontAttributeName: Ref;
    extern var kCGColorSpaceSRGB: Ref;
    extern fn CFRelease(Ref) void;
    extern fn CFEqual(Ref, Ref) bool;
    extern fn CFStringCreateWithBytes(Ref, [*]const u8, isize, u32, bool) Ref;
    extern fn CFStringGetRangeOfComposedCharactersAtIndex(Ref, isize) Range;
    extern fn CFAttributedStringCreateMutable(Ref, isize) Ref;
    extern fn CFAttributedStringReplaceString(Ref, Range, Ref) void;
    extern fn CFAttributedStringSetAttribute(Ref, Range, Ref, Ref) void;
    extern fn CFDictionaryGetValue(Ref, Ref) Ref;
    extern fn CFArrayGetCount(Ref) isize;
    extern fn CFArrayGetValueAtIndex(Ref, isize) Ref;
    extern fn CTFontCreateWithName(Ref, f64, ?*const anyopaque) Ref;
    extern fn CTFontCreateCopyWithAttributes(Ref, f64, ?*const anyopaque, Ref) Ref;
    extern fn CTFontCreateCopyWithSymbolicTraits(Ref, f64, ?*const anyopaque, u32, u32) Ref;
    extern fn CTFontGetSymbolicTraits(Ref) u32;
    extern fn CTFontGetUnitsPerEm(Ref) u32;
    extern fn CTFontGetAscent(Ref) f64;
    extern fn CTFontGetDescent(Ref) f64;
    extern fn CTFontGetLeading(Ref) f64;
    extern fn CTFontGetCapHeight(Ref) f64;
    extern fn CTFontGetXHeight(Ref) f64;
    extern fn CTFontGetBoundingRectsForGlyphs(Ref, c_int, [*]const u16, ?[*]Rect, isize) Rect;
    extern fn CTFontDrawGlyphs(Ref, [*]const u16, [*]const Point, usize, Ref) void;
    extern fn CTLineCreateWithAttributedString(Ref) Ref;
    extern fn CTLineGetGlyphRuns(Ref) Ref;
    extern fn CTLineGetTypographicBounds(Ref, ?*f64, ?*f64, ?*f64) f64;
    extern fn CTLineGetOffsetForStringIndex(Ref, isize, ?*f64) f64;
    extern fn CTRunGetAttributes(Ref) Ref;
    extern fn CTRunGetGlyphCount(Ref) isize;
    extern fn CTRunGetGlyphs(Ref, Range, [*]u16) void;
    extern fn CTRunGetPositions(Ref, Range, [*]Point) void;
    extern fn CTRunGetAdvances(Ref, Range, [*]Size) void;
    extern fn CTRunGetStringIndices(Ref, Range, [*]isize) void;
    extern fn CGColorSpaceCreateDeviceGray() Ref;
    extern fn CGColorSpaceCreateWithName(Ref) Ref;
    extern fn CGColorSpaceRelease(Ref) void;
    extern fn CGBitmapContextCreate(?*anyopaque, usize, usize, usize, usize, Ref, u32) Ref;
    extern fn CGContextSetGrayFillColor(Ref, f64, f64) void;
    extern fn CGContextSetRGBFillColor(Ref, f64, f64, f64, f64) void;
    extern fn CGContextSetShouldAntialias(Ref, bool) void;
    extern fn CGContextSetShouldSmoothFonts(Ref, bool) void;
    extern fn CGContextRelease(Ref) void;
};

/// Bidirectional offset conversion for CoreText's UTF-16 ranges and GPUI-style
/// UTF-8 byte indexes. Both halves of a surrogate pair map to its UTF-8 start.
pub const StringIndexMap = struct {
    utf16_to_utf8: []usize,
    utf8_to_utf16: []usize,
    pub fn init(a: std.mem.Allocator, bytes: []const u8) !StringIndexMap {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        const to16 = try a.alloc(usize, bytes.len + 1);
        errdefer a.free(to16);
        var to8: std.ArrayList(usize) = .empty;
        errdefer to8.deinit(a);
        var i: usize = 0;
        while (i < bytes.len) {
            const len = try std.unicode.utf8ByteSequenceLength(bytes[i]);
            const cp = try std.unicode.utf8Decode(bytes[i..][0..len]);
            @memset(to16[i..][0..len], to8.items.len);
            try to8.append(a, i);
            if (cp > 0xffff) try to8.append(a, i);
            i += len;
        }
        to16[bytes.len] = to8.items.len;
        try to8.append(a, bytes.len);
        return .{ .utf16_to_utf8 = try to8.toOwnedSlice(a), .utf8_to_utf16 = to16 };
    }
    pub fn deinit(self: StringIndexMap, a: std.mem.Allocator) void {
        a.free(self.utf16_to_utf8);
        a.free(self.utf8_to_utf16);
    }
};

/// Owns normalized, one-point CTFonts. Shaped fallback fonts are interned here
/// too, so rasterization always uses the actual font that produced each glyph.
const MacTextSystem = struct {
    allocator: std.mem.Allocator,
    fonts: std.ArrayList(native.Ref) = .empty,
    fn cast(ptr: *anyopaque) *MacTextSystem {
        return @ptrCast(@alignCast(ptr));
    }
    fn deinit(ptr: *anyopaque) void {
        const self = cast(ptr);
        for (self.fonts.items) |font_ref| native.CFRelease(font_ref);
        self.fonts.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    fn font(self: *MacTextSystem, id: text.FontId) !native.Ref {
        const index = @intFromEnum(id);
        if (index >= self.fonts.items.len) return error.InvalidFontId;
        return self.fonts.items[index];
    }
    fn intern(self: *MacTextSystem, source: native.Ref) !text.FontId {
        const normalized = native.CTFontCreateCopyWithAttributes(source, 1, null, null) orelse return error.FontUnavailable;
        errdefer native.CFRelease(normalized);
        for (self.fonts.items, 0..) |existing, i| if (native.CFEqual(existing, normalized)) {
            native.CFRelease(normalized);
            return @enumFromInt(i);
        };
        const id: text.FontId = @enumFromInt(@as(u32, @intCast(self.fonts.items.len)));
        try self.fonts.append(self.allocator, normalized);
        return id;
    }
    fn string(bytes: []const u8) !native.Ref {
        return native.CFStringCreateWithBytes(null, bytes.ptr, @intCast(bytes.len), 0x08000100, false) orelse error.TextUnavailable;
    }
    fn fontId(ptr: *anyopaque, descriptor: text.Font) !text.FontId {
        const self = cast(ptr);
        const name = try string(descriptor.family);
        defer native.CFRelease(name);
        const base = native.CTFontCreateWithName(name, 1, null) orelse return error.FontUnavailable;
        defer native.CFRelease(base);
        const traits: u32 = (if (descriptor.style == .italic) @as(u32, 1) else 0) | (if (descriptor.weight == .bold) @as(u32, 2) else 0);
        if (traits == 0) return self.intern(base);
        const styled = native.CTFontCreateCopyWithSymbolicTraits(base, 1, null, traits, 3) orelse return error.FontUnavailable;
        defer native.CFRelease(styled);
        return self.intern(styled);
    }
    fn fontMetrics(ptr: *anyopaque, id: text.FontId) !text.FontMetrics {
        const ctfont = try cast(ptr).font(id);
        const upem: f64 = @floatFromInt(native.CTFontGetUnitsPerEm(ctfont));
        return .{ .units_per_em = @floatCast(upem), .ascent = @floatCast(native.CTFontGetAscent(ctfont) * upem), .descent = @floatCast(native.CTFontGetDescent(ctfont) * upem), .leading = @floatCast(native.CTFontGetLeading(ctfont) * upem), .cap_height = @floatCast(native.CTFontGetCapHeight(ctfont) * upem), .x_height = @floatCast(native.CTFontGetXHeight(ctfont) * upem) };
    }
    fn layoutLine(ptr: *anyopaque, a: std.mem.Allocator, bytes: []const u8, font_size: f32, font_runs: []const text.FontRun) !*text.LineLayout {
        const self = cast(ptr);
        const result = try text.LineLayout.create(a);
        errdefer result.release();
        const memory = result.memory();
        const map = try StringIndexMap.init(memory, bytes);
        const source = try string(bytes);
        defer native.CFRelease(source);
        const attributed = native.CFAttributedStringCreateMutable(null, 0) orelse return error.TextUnavailable;
        defer native.CFRelease(attributed);
        native.CFAttributedStringReplaceString(attributed, .{ .location = 0, .length = 0 }, source);
        var offset: usize = 0;
        for (font_runs) |run| {
            const sized = native.CTFontCreateCopyWithAttributes(try self.font(run.font_id), font_size, null, null) orelse return error.FontUnavailable;
            defer native.CFRelease(sized);
            native.CFAttributedStringSetAttribute(attributed, .{ .location = @intCast(map.utf8_to_utf16[offset]), .length = @intCast(map.utf8_to_utf16[offset + run.len] - map.utf8_to_utf16[offset]) }, native.kCTFontAttributeName, sized);
            offset += run.len;
        }
        const line = native.CTLineCreateWithAttributedString(attributed) orelse return error.ShapingFailed;
        defer native.CFRelease(line);
        var ascent: f64 = 0;
        var descent: f64 = 0;
        var leading: f64 = 0;
        result.width = @floatCast(native.CTLineGetTypographicBounds(line, &ascent, &descent, &leading));
        if (bytes.len == 0) {
            const metrics = try fontMetrics(ptr, font_runs[0].font_id);
            ascent = metrics.ascent / metrics.units_per_em * font_size;
            descent = metrics.descent / metrics.units_per_em * font_size;
            leading = metrics.leading / metrics.units_per_em * font_size;
        }
        result.ascent = @floatCast(ascent);
        result.descent = @floatCast(descent);
        result.leading = @floatCast(leading);
        const runs = native.CTLineGetGlyphRuns(line);
        var shaped: std.ArrayList(text.ShapedRun) = .empty;
        for (0..@intCast(native.CFArrayGetCount(runs))) |i| {
            const run = native.CFArrayGetValueAtIndex(runs, @intCast(i));
            const actual_font = native.CFDictionaryGetValue(native.CTRunGetAttributes(run), native.kCTFontAttributeName) orelse return error.FontUnavailable;
            const font_id = try self.intern(actual_font);
            const count: usize = @intCast(native.CTRunGetGlyphCount(run));
            const ids = try memory.alloc(u16, count);
            const positions = try memory.alloc(native.Point, count);
            const advances = try memory.alloc(native.Size, count);
            const indexes = try memory.alloc(isize, count);
            const all = native.Range{ .location = 0, .length = @intCast(count) };
            native.CTRunGetGlyphs(run, all, ids.ptr);
            native.CTRunGetPositions(run, all, positions.ptr);
            native.CTRunGetAdvances(run, all, advances.ptr);
            native.CTRunGetStringIndices(run, all, indexes.ptr);
            const glyphs = try memory.alloc(text.ShapedGlyph, count);
            for (glyphs, 0..) |*glyph, j| {
                if (indexes[j] < 0 or indexes[j] >= map.utf16_to_utf8.len) return error.InvalidGlyphCluster;
                glyph.* = .{ .id = ids[j], .position = .{ .x = @floatCast(positions[j].x), .y = @floatCast(-positions[j].y) }, .advance = @floatCast(advances[j].width), .index = map.utf16_to_utf8[@intCast(indexes[j])], .is_emoji = native.CTFontGetSymbolicTraits(actual_font) & (1 << 13) != 0 };
            }
            try shaped.append(memory, .{ .font_id = font_id, .glyphs = glyphs });
        }
        result.runs = shaped.items;
        var carets: std.ArrayList(text.Caret) = .empty;
        var index: usize = 0;
        const utf16_len = map.utf16_to_utf8.len - 1;
        while (index < utf16_len) {
            try carets.append(memory, .{ .index = map.utf16_to_utf8[index], .x = @floatCast(native.CTLineGetOffsetForStringIndex(line, @intCast(index), null)) });
            const cluster = native.CFStringGetRangeOfComposedCharactersAtIndex(source, @intCast(index));
            if (cluster.length <= 0) return error.InvalidGlyphCluster;
            index = @intCast(cluster.location + cluster.length);
        }
        try carets.append(memory, .{ .index = bytes.len, .x = @floatCast(native.CTLineGetOffsetForStringIndex(line, @intCast(utf16_len), null)) });
        result.carets = carets.items;
        return result;
    }
    fn sizedFont(self: *MacTextSystem, params: text.RenderGlyphParams) !native.Ref {
        if (params.glyph_id > std.math.maxInt(u16)) return error.InvalidGlyphId;
        return native.CTFontCreateCopyWithAttributes(try self.font(params.font_id), @as(f64, params.font_size) * params.scale, null, null) orelse error.FontUnavailable;
    }
    fn rasterBounds(ptr: *anyopaque, params: text.RenderGlyphParams) !text.RasterBounds {
        const font_ref = try cast(ptr).sizedFont(params);
        defer native.CFRelease(font_ref);
        const glyph: u16 = @intCast(params.glyph_id);
        const bounds = native.CTFontGetBoundingRectsForGlyphs(font_ref, 0, @ptrCast(&glyph), null, 1);
        if (bounds.size.width <= 0 or bounds.size.height <= 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const dx = @as(f64, @floatFromInt(params.subpixel[0])) / 4;
        const dy = @as(f64, @floatFromInt(params.subpixel[1])) / 4;
        const min_x = @floor(bounds.origin.x + dx) - 1;
        const max_x = @ceil(bounds.origin.x + bounds.size.width + dx) + 1;
        const min_y = @floor(bounds.origin.y - dy) - 1;
        const max_y = @ceil(bounds.origin.y + bounds.size.height - dy) + 1;
        if (max_x - min_x > 8192 or max_y - min_y > 8192) return error.GlyphTooLarge;
        return .{ .x = @intFromFloat(min_x), .y = @intFromFloat(-max_y), .width = @intFromFloat(max_x - min_x), .height = @intFromFloat(max_y - min_y) };
    }
    fn rasterize(ptr: *anyopaque, a: std.mem.Allocator, params: text.RenderGlyphParams, bounds: text.RasterBounds) !text.RasterizedGlyph {
        const font_ref = try cast(ptr).sizedFont(params);
        defer native.CFRelease(font_ref);
        const color = native.CTFontGetSymbolicTraits(font_ref) & (1 << 13) != 0;
        const stride: usize = @as(usize, bounds.width) * (if (color) @as(usize, 4) else 1);
        const pixels = try a.alloc(u8, stride * bounds.height);
        errdefer a.free(pixels);
        @memset(pixels, 0);
        if (pixels.len > 0) {
            const colorspace = (if (color) native.CGColorSpaceCreateWithName(native.kCGColorSpaceSRGB) else native.CGColorSpaceCreateDeviceGray()) orelse return error.RasterizationFailed;
            defer native.CGColorSpaceRelease(colorspace);
            const ctx = native.CGBitmapContextCreate(pixels.ptr, bounds.width, bounds.height, 8, stride, colorspace, if (color) 16385 else 0) orelse return error.RasterizationFailed;
            defer native.CGContextRelease(ctx);
            native.CGContextSetShouldAntialias(ctx, true);
            native.CGContextSetShouldSmoothFonts(ctx, false);
            if (color) native.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1) else native.CGContextSetGrayFillColor(ctx, 1, 1);
            const glyph: u16 = @intCast(params.glyph_id);
            const origin = native.Point{ .x = @as(f64, @floatFromInt(params.subpixel[0])) / 4 - @as(f64, @floatFromInt(bounds.x)), .y = -@as(f64, @floatFromInt(params.subpixel[1])) / 4 + @as(f64, @floatFromInt(bounds.y)) + @as(f64, @floatFromInt(bounds.height)) };
            native.CTFontDrawGlyphs(font_ref, @ptrCast(&glyph), @ptrCast(&origin), 1, ctx);
        }
        return .{ .bounds = bounds, .format = if (color) .rgba8 else .alpha8, .pixels = pixels };
    }
    const vtable: text.PlatformTextSystem.VTable = .{ .deinit = deinit, .font_id = fontId, .font_metrics = fontMetrics, .layout_line = layoutLine, .glyph_raster_bounds = rasterBounds, .rasterize_glyph = rasterize };
};

pub fn create(a: std.mem.Allocator) !text.PlatformTextSystem {
    const self = try a.create(MacTextSystem);
    self.* = .{ .allocator = a };
    return .{ .ptr = self, .vtable = &MacTextSystem.vtable };
}

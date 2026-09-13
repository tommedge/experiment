const std = @import("std");
const t = std.testing;
const ts = @import("text_system.zig");
const mac = @import("platform/macos/text.zig");

fn service() !*ts.TextSystem {
    const backend = try mac.create(t.allocator);
    errdefer backend.deinit();
    return ts.TextSystem.create(t.allocator, backend);
}
test "CoreText shapes fallback fonts, grapheme carets, RTL, and colored emoji" {
    const system = try service();
    defer system.release();
    const font = try system.fontId(.{ .family = "Helvetica" });
    try t.expectEqual(font, try system.fontId(.{ .family = "Helvetica" }));
    const metrics = try system.fontMetrics(font);
    try t.expect(metrics.units_per_em > 0 and metrics.ascent > 0 and metrics.cap_height > 0);
    const value = "office café e\u{301} 👩‍💻 שלום العربية";
    const line = try system.shapeLine(value, 24, &.{.{ .len = value.len, .font_id = font }});
    defer line.release();
    try t.expect(line.width > 0 and line.ascent > 0);
    var fallback = false;
    var color = false;
    var glyph_count: usize = 0;
    for (line.runs) |run| {
        if (run.font_id != font) fallback = true;
        for (run.glyphs) |glyph| {
            glyph_count += 1;
            try t.expect(glyph.index < value.len and value[glyph.index] & 0xc0 != 0x80);
            var bitmap = try system.rasterizeGlyph(t.allocator, .{ .font_id = run.font_id, .glyph_id = glyph.id, .font_size = 24, .scale = 2 });
            defer bitmap.deinit(t.allocator);
            if (glyph.is_emoji) {
                try t.expectEqual(ts.RasterFormat.rgba8, bitmap.format);
                try t.expect(std.mem.indexOfNone(u8, bitmap.pixels, &.{0}) != null);
                color = true;
            }
        }
    }
    try t.expect(glyph_count > 10 and fallback and color);
    const combining = std.mem.indexOf(u8, value, "e\u{301}").?;
    const emoji = std.mem.indexOf(u8, value, "👩‍💻").?;
    for (line.carets) |caret| {
        try t.expect(caret.index != combining + 1);
        try t.expect(caret.index <= emoji or caret.index >= emoji + "👩‍💻".len);
    }
    const rtl = "שלום";
    const right = try system.shapeLine(rtl, 24, &.{.{ .len = rtl.len, .font_id = font }});
    defer right.release();
    try t.expect(right.xForIndex(0) > right.xForIndex(rtl.len));
    try t.expectEqual(@as(usize, 0), right.closestIndexForX(right.xForIndex(0)));
    const empty = try system.shapeLine("", 24, &.{.{ .len = 0, .font_id = font }});
    defer empty.release();
    try t.expect(empty.ascent > 0 and empty.width == 0);
}

test "CoreText raster is top-to-bottom, scales, and distinguishes fonts and phases" {
    const system = try service();
    defer system.release();
    const font = try system.fontId(.{ .family = "Helvetica" });
    const line = try system.shapeLine("F", 36, &.{.{ .len = 1, .font_id = font }});
    defer line.release();
    const glyph = line.runs[0].glyphs[0];
    var normal = try system.rasterizeGlyph(t.allocator, .{ .font_id = font, .glyph_id = glyph.id, .font_size = 36, .scale = 1 });
    defer normal.deinit(t.allocator);
    var retina = try system.rasterizeGlyph(t.allocator, .{ .font_id = font, .glyph_id = glyph.id, .font_size = 36, .scale = 2, .subpixel = .{ 1, 2 } });
    defer retina.deinit(t.allocator);
    try t.expectEqual(ts.RasterFormat.alpha8, normal.format);
    try t.expect(retina.bounds.height > normal.bounds.height);
    var top: usize = 0;
    var bottom: usize = 0;
    for (normal.pixels, 0..) |pixel, i| {
        if (i / normal.bounds.width < normal.bounds.height / 2) top += pixel else bottom += pixel;
    }
    try t.expect(top > bottom); // F has horizontal strokes in its upper half.
    const map = try mac.StringIndexMap.init(t.allocator, "a🐳é");
    defer map.deinit(t.allocator);
    try t.expectEqualSlices(usize, &.{ 0, 1, 1, 5, 7 }, map.utf16_to_utf8);
}

const std = @import("std");
const t = std.testing;
const g = @import("geometry.zig");
const Scene = @import("scene.zig").Scene;
const Metal = @import("renderer/metal.zig").Metal;
const text = @import("text_system.zig");
const objc = @import("objc");

fn pixel(bytes: []const u8, x: usize, y: usize) []const u8 {
    return bytes[(y * 24 + x) * 4 ..][0..4];
}
fn expectPixel(expected: [4]u8, actual: []const u8) !void {
    for (expected, actual) |a, b| try t.expect(@abs(@as(i16, a) - @as(i16, b)) <= 2);
}

test "Metal source-over handles overlapping quads, ordering, clipping and zero alpha" {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var renderer = try Metal.init(t.allocator, .{ .width = 24, .height = 24 }, 1);
    defer renderer.deinit();
    const clip = g.Bounds{ .size = renderer.size };
    const red = @import("scene.zig").Quad{ .bounds = .{ .origin = .{ .x = 2, .y = 2 }, .size = .{ .width = 12, .height = 12 } }, .clip = clip, .color = .{ .r = 1, .a = 0.5 } };
    const blue = @import("scene.zig").Quad{ .bounds = .{ .origin = .{ .x = 8, .y = 2 }, .size = .{ .width = 12, .height = 12 } }, .clip = clip, .color = .{ .b = 1, .a = 0.5 } };
    var scene: Scene = .{};
    defer scene.deinit(t.allocator);
    try scene.quad(t.allocator, red);
    try scene.quad(t.allocator, blue);
    try scene.quad(t.allocator, .{ .bounds = clip, .clip = clip, .color = .{ .r = 1, .b = 1, .a = 0 } });
    const first = try renderer.readPixelsForTest(&scene, t.allocator);
    defer t.allocator.free(first);
    try expectPixel(.{ 0, 0, 188, 128 }, pixel(first, 4, 4));
    try expectPixel(.{ 188, 0, 137, 191 }, pixel(first, 10, 4));
    try expectPixel(.{ 188, 0, 0, 128 }, pixel(first, 18, 4));
    try expectPixel(.{ 0, 0, 0, 0 }, pixel(first, 0, 0));
    var reversed: Scene = .{};
    defer reversed.deinit(t.allocator);
    try reversed.quad(t.allocator, blue);
    try reversed.quad(t.allocator, red);
    const reverse = try renderer.readPixelsForTest(&reversed, t.allocator);
    defer t.allocator.free(reverse);
    try expectPixel(.{ 137, 0, 188, 191 }, pixel(reverse, 10, 4));
    var solid: Scene = .{};
    defer solid.deinit(t.allocator);
    try solid.quad(t.allocator, .{ .bounds = clip, .clip = clip, .color = .{ .g = 1 } });
    var clipped = red;
    clipped.clip = .{ .size = .{ .width = 9, .height = 24 } };
    try solid.quad(t.allocator, clipped);
    try solid.quad(t.allocator, blue);
    const background = try renderer.readPixelsForTest(&solid, t.allocator);
    defer t.allocator.free(background);
    try expectPixel(.{ 188, 137, 137, 255 }, pixel(background, 8, 4));
    try expectPixel(.{ 188, 188, 0, 255 }, pixel(background, 10, 4));
}

test "transparent quads and coverage glyphs compose in scene order across atlas batches" {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var renderer = try Metal.init(t.allocator, .{ .width = 24, .height = 24 }, 1);
    defer renderer.deinit();
    const backend = try text.stub.create(t.allocator);
    const fonts = text.TextSystem.create(t.allocator, backend) catch |err| {
        backend.deinit();
        return err;
    };
    defer fonts.release();
    const font = try fonts.fontId(.{});
    const clip = g.Bounds{ .size = renderer.size };
    var scene: Scene = .{};
    defer scene.deinit(t.allocator);
    try scene.quad(t.allocator, .{ .bounds = clip, .clip = clip, .color = .{ .r = 1, .a = 0.5 } });
    try scene.glyph(t.allocator, .{ .system = fonts, .font_id = font, .glyph_id = 'A', .font_size = 10, .position = .{ .x = 4, .y = 12 }, .clip = clip, .color = .{ .g = 1, .a = 0.5 } });
    try scene.quad(t.allocator, .{ .bounds = .{ .origin = .{ .x = 6, .y = 4 }, .size = .{ .width = 4, .height = 10 } }, .clip = clip, .color = .{ .b = 1, .a = 0.5 } });
    const result = try renderer.readPixelsForTest(&scene, t.allocator);
    defer t.allocator.free(result);
    try expectPixel(.{ 0, 188, 137, 191 }, pixel(result, 5, 6));
    try expectPixel(.{ 188, 137, 99, 223 }, pixel(result, 7, 6));
}

fn linear(value: u8) f32 {
    const encoded = @as(f32, @floatFromInt(value)) / 255;
    return if (encoded <= 0.04045) encoded / 12.92 else std.math.pow(f32, (encoded + 0.055) / 1.055, 2.4);
}
test "color glyph opacity uses the same premultiplied blend contract" {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var renderer = try Metal.init(t.allocator, .{ .width = 24, .height = 24 }, 1);
    defer renderer.deinit();
    const backend = try @import("platform/macos/text.zig").create(t.allocator);
    const fonts = text.TextSystem.create(t.allocator, backend) catch |err| {
        backend.deinit();
        return err;
    };
    defer fonts.release();
    const font = try fonts.fontId(.{ .family = "Helvetica" });
    const line = try fonts.shapeLine("🐳", 16, &.{.{ .len = "🐳".len, .font_id = font }});
    defer line.release();
    const run = line.runs[0];
    const glyph = run.glyphs[0];
    try t.expect(glyph.is_emoji);
    var images: [3][]u8 = undefined;
    var completed: usize = 0;
    defer for (images[0..completed]) |image| t.allocator.free(image);
    for ([_]f32{ 1, 0.5, 0 }, 0..) |opacity, index| {
        var scene: Scene = .{};
        defer scene.deinit(t.allocator);
        try scene.glyph(t.allocator, .{ .system = fonts, .font_id = run.font_id, .glyph_id = glyph.id, .font_size = 16, .position = .{ .x = 2 + glyph.position.x, .y = 2 + line.ascent + glyph.position.y }, .clip = .{ .size = renderer.size }, .color = .{ .a = opacity } });
        images[index] = try renderer.readPixelsForTest(&scene, t.allocator);
        completed += 1;
    }
    var covered: usize = 0;
    for (0..24 * 24) |i| {
        const full = images[0][i * 4 ..][0..4];
        const half = images[1][i * 4 ..][0..4];
        if (full[3] > 0) covered += 1;
        try t.expect(@abs(@as(f32, @floatFromInt(half[3])) - @as(f32, @floatFromInt(full[3])) * 0.5) <= 1);
        for (0..3) |channel| try t.expectApproxEqAbs(linear(full[channel]) * 0.5, linear(half[channel]), 0.01);
        try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, images[2][i * 4 ..][0..4]);
    }
    try t.expect(covered > 0);
}

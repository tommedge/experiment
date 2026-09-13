const std = @import("std");
const t = std.testing;
const g = @import("geometry.zig");
const scene_types = @import("scene.zig");
const Metal = @import("renderer/metal.zig").Metal;
const objc = @import("objc");

fn pixel(bytes: []const u8, width: usize, x: usize, y: usize) []const u8 {
    return bytes[(y * width + x) * 4 ..][0..4];
}
fn alpha(bytes: []const u8, width: usize, x: usize, y: usize) u8 {
    return pixel(bytes, width, x, y)[3];
}

test "Metal rounded SDF cuts corners, antialiases, and composites translucent borders once" {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var renderer = try Metal.init(t.allocator, .{ .width = 40, .height = 40 }, 1);
    defer renderer.deinit();
    var scene: scene_types.Scene = .{};
    defer scene.deinit(t.allocator);
    const bounds = g.Bounds{ .origin = .{ .x = 4, .y = 4 }, .size = .{ .width = 32, .height = 32 } };
    try scene.quad(t.allocator, .{ .bounds = bounds, .clip = .{ .size = renderer.size }, .color = .{ .b = 1, .a = 0.5 }, .border_widths = .all(4), .border_color = .{ .r = 1, .a = 0.5 }, .corner_radii = .all(10) });
    const bytes = try renderer.readPixelsForTest(&scene, t.allocator);
    defer t.allocator.free(bytes);
    try t.expectEqual(@as(u8, 0), alpha(bytes, 40, 4, 4));
    try t.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(alpha(bytes, 40, 20, 20))), 1);
    const border = pixel(bytes, 40, 20, 5);
    try t.expectApproxEqAbs(@as(f32, 191), @as(f32, @floatFromInt(border[3])), 1);
    try t.expectEqual(border[3], alpha(bytes, 40, 8, 8)); // Curved corner blends just once too.
    // BGRA sRGB encodes premultiplied linear blue=0.25, red=0.5.
    try t.expectApproxEqAbs(@as(f32, 137), @as(f32, @floatFromInt(border[0])), 2);
    try t.expectApproxEqAbs(@as(f32, 188), @as(f32, @floatFromInt(border[2])), 2);
    var partial = false;
    for (4..14) |y| for (4..14) |x| {
        const a = alpha(bytes, 40, x, y);
        if (a > 0 and a < 120) partial = true;
    };
    try t.expect(partial);
}

test "Metal analytic clipping preserves the original shape at 1x and 2x" {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    for ([_]f32{ 1, 2 }) |scale| {
        var renderer = try Metal.init(t.allocator, .{ .width = 40, .height = 40 }, scale);
        defer renderer.deinit();
        const bounds = g.Bounds{ .origin = .{ .x = 4, .y = 4 }, .size = .{ .width = 32, .height = 32 } };
        var full: scene_types.Scene = .{};
        defer full.deinit(t.allocator);
        const quad = scene_types.Quad{ .bounds = bounds, .clip = .{ .size = renderer.size }, .color = .{ .g = 1 }, .border_color = .{ .r = 1 }, .border_widths = .{ .left = 6, .top = 2, .right = 0, .bottom = 4 }, .corner_radii = .{ .top_left = 10, .top_right = 2, .bottom_right = 0, .bottom_left = 8 } };
        try full.quad(t.allocator, quad);
        var clipped: scene_types.Scene = .{};
        defer clipped.deinit(t.allocator);
        var cut = quad;
        cut.clip = .{ .origin = .{ .x = 9, .y = 6 }, .size = .{ .width = 19, .height = 24 } };
        try clipped.quad(t.allocator, cut);
        const original = try renderer.readPixelsForTest(&full, t.allocator);
        defer t.allocator.free(original);
        const actual = try renderer.readPixelsForTest(&clipped, t.allocator);
        defer t.allocator.free(actual);
        const factor: usize = @intFromFloat(scale);
        const side = 40 * factor;
        for (0..side) |y| for (0..side) |x| {
            if (x >= 9 * factor and x < 28 * factor and y >= 6 * factor and y < 30 * factor) {
                const expected = pixel(original, side, x, y);
                const got = pixel(actual, side, x, y);
                for (expected, got) |a, b| try t.expect(@abs(@as(i16, a) - @as(i16, b)) <= 1);
            } else try t.expectEqual(@as(u8, 0), alpha(actual, side, x, y));
        };
        // The independently square BR corner stays filled, while TL is cut away.
        try t.expectEqual(@as(u8, 0), alpha(original, side, 4 * factor, 4 * factor));
        try t.expectEqual(@as(u8, 255), alpha(original, side, 35 * factor, 35 * factor));
        // Missing right border leaves the fill visible along its straight segment.
        try t.expect(pixel(original, side, 35 * factor, 20 * factor)[1] > 250);
        if (factor == 1) {
            // Near the TL inner ellipse (radii 4x8), this pixel is mostly fill.
            // A circular inset using either edge width gives a different result.
            const ellipse_edge = pixel(original, side, 11, 8);
            try t.expect(ellipse_edge[2] > 30 and ellipse_edge[2] < 150);
            try t.expect(ellipse_edge[1] > 200);
        }
    }
}

test "Metal rounded outlines have transparent interiors and handle collapsed inner radii" {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var renderer = try Metal.init(t.allocator, .{ .width = 32, .height = 32 }, 1);
    defer renderer.deinit();
    const bounds = g.Bounds{ .size = renderer.size };
    var outline: scene_types.Scene = .{};
    defer outline.deinit(t.allocator);
    try outline.border(t.allocator, .{ .bounds = bounds, .clip = bounds, .widths = .{ .left = 10, .top = 2, .right = 0, .bottom = 20 }, .color = .{ .r = 1, .a = 0.5 }, .corner_radii = .all(10) });
    const bytes = try renderer.readPixelsForTest(&outline, t.allocator);
    defer t.allocator.free(bytes);
    try t.expectEqual(@as(u8, 0), alpha(bytes, 32, 16, 6));
    try t.expectEqual(@as(u8, 0), alpha(bytes, 32, 31, 8));
    try t.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(alpha(bytes, 32, 16, 20))), 1);
    for (0..32 * 32) |i| try t.expect(bytes[i * 4 + 3] <= 128);
    var fill: scene_types.Scene = .{};
    defer fill.deinit(t.allocator);
    try fill.quad(t.allocator, .{ .bounds = bounds, .clip = bounds, .color = .{ .g = 1 }, .border_color = .{ .r = 1 }, .corner_radii = .all(10) });
    const no_border = try renderer.readPixelsForTest(&fill, t.allocator);
    defer t.allocator.free(no_border);
    for (0..32 * 32) |i| try t.expectEqual(@as(u8, 0), no_border[i * 4 + 2]);
}

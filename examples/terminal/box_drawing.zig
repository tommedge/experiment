// Cell-aligned box/block drawing adapted from ../editor/src/terminal.zig.
// As in that example, mixed/double-line junctions are approximated geometrically.
const ui = @import("zigui");
const g = ui.geometry;

/// Connectivity or fractional coverage within one terminal cell.
pub const Glyph = union(enum) {
    segments: struct { up: bool = false, down: bool = false, left: bool = false, right: bool = false, heavy: bool = false },
    block: struct { x: f32 = 0, y: f32 = 0, width: f32 = 1, height: f32 = 1, alpha: f32 = 1 },
    quadrants: u4,
};
pub fn lookup(cp: u21) ?Glyph {
    return switch (cp) {
        0x2500, 0x2504, 0x2508, 0x254c, 0x2550 => .{ .segments = .{ .left = true, .right = true } },
        0x2501, 0x2505, 0x2509, 0x254d => .{ .segments = .{ .left = true, .right = true, .heavy = true } },
        0x2502, 0x2506, 0x250a, 0x254e, 0x2551 => .{ .segments = .{ .up = true, .down = true } },
        0x2503, 0x2507, 0x250b, 0x254f => .{ .segments = .{ .up = true, .down = true, .heavy = true } },
        0x250c...0x250f, 0x2552...0x2554, 0x256d => .{ .segments = .{ .down = true, .right = true } },
        0x2510...0x2513, 0x2555...0x2557, 0x256e => .{ .segments = .{ .down = true, .left = true } },
        0x2514...0x2517, 0x2558...0x255a, 0x2570 => .{ .segments = .{ .up = true, .right = true } },
        0x2518...0x251b, 0x255b...0x255d, 0x256f => .{ .segments = .{ .up = true, .left = true } },
        0x251c...0x2523, 0x255e...0x2560 => .{ .segments = .{ .up = true, .down = true, .right = true } },
        0x2524...0x252b, 0x2561...0x2563 => .{ .segments = .{ .up = true, .down = true, .left = true } },
        0x252c...0x2533, 0x2564...0x2566 => .{ .segments = .{ .down = true, .left = true, .right = true } },
        0x2534...0x253b, 0x2567...0x2569 => .{ .segments = .{ .up = true, .left = true, .right = true } },
        0x253c...0x254b, 0x256a...0x256c => .{ .segments = .{ .up = true, .down = true, .left = true, .right = true } },
        0x2574 => .{ .segments = .{ .left = true } },
        0x2575 => .{ .segments = .{ .up = true } },
        0x2576 => .{ .segments = .{ .right = true } },
        0x2577 => .{ .segments = .{ .down = true } },
        0x2578 => .{ .segments = .{ .left = true, .heavy = true } },
        0x2579 => .{ .segments = .{ .up = true, .heavy = true } },
        0x257a => .{ .segments = .{ .right = true, .heavy = true } },
        0x257b => .{ .segments = .{ .down = true, .heavy = true } },
        0x257c, 0x257e => .{ .segments = .{ .left = true, .right = true } },
        0x257d, 0x257f => .{ .segments = .{ .up = true, .down = true } },
        0x2580 => .{ .block = .{ .height = 0.5 } },
        0x2581...0x2588 => blk: {
            const n: f32 = @floatFromInt(cp - 0x2580);
            break :blk .{ .block = .{ .y = 1 - n / 8, .height = n / 8 } };
        },
        0x2589...0x258f => .{ .block = .{ .width = @as(f32, @floatFromInt(0x2590 - cp)) / 8 } },
        0x2590 => .{ .block = .{ .x = 0.5, .width = 0.5 } },
        0x2591 => .{ .block = .{ .alpha = 0.25 } },
        0x2592 => .{ .block = .{ .alpha = 0.5 } },
        0x2593 => .{ .block = .{ .alpha = 0.75 } },
        0x2594 => .{ .block = .{ .height = 0.125 } },
        0x2595 => .{ .block = .{ .x = 0.875, .width = 0.125 } },
        0x2596 => .{ .quadrants = 0b0100 },
        0x2597 => .{ .quadrants = 0b1000 },
        0x2598 => .{ .quadrants = 0b0001 },
        0x2599 => .{ .quadrants = 0b1101 },
        0x259a => .{ .quadrants = 0b1001 },
        0x259b => .{ .quadrants = 0b0111 },
        0x259c => .{ .quadrants = 0b1011 },
        0x259d => .{ .quadrants = 0b0010 },
        0x259e => .{ .quadrants = 0b0110 },
        0x259f => .{ .quadrants = 0b1110 },
        else => null,
    };
}
fn fill(f: anytype, cell: g.Bounds, color: g.Color, x: f32, y: f32, width: f32, height: f32) !void {
    try f.scene.quad(f.allocator(), .{ .bounds = .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } }, .color = color, .clip = cell.intersect(f.clip) });
}
pub fn paint(f: anytype, cell: g.Bounds, glyph: Glyph, color: g.Color) !void {
    const x = cell.origin.x;
    const y = cell.origin.y;
    const w = cell.size.width;
    const h = cell.size.height;
    switch (glyph) {
        .segments => |s| {
            const thickness: f32 = if (s.heavy) 2 else 1;
            const cx = x + @floor((w - thickness) * f.scale / 2) / f.scale;
            const cy = y + @floor((h - thickness) * f.scale / 2) / f.scale;
            if (s.up and s.down) try fill(f, cell, color, cx, y, thickness, h) else if (s.up) try fill(f, cell, color, cx, y, thickness, cy - y + thickness) else if (s.down) try fill(f, cell, color, cx, cy, thickness, y + h - cy);
            if (s.left and s.right) try fill(f, cell, color, x, cy, w, thickness) else if (s.left) try fill(f, cell, color, x, cy, cx - x + thickness, thickness) else if (s.right) try fill(f, cell, color, cx, cy, x + w - cx, thickness);
        },
        .block => |block| {
            var faded = color;
            faded.a *= block.alpha;
            try fill(f, cell, faded, x + w * block.x, y + h * block.y, w * block.width, h * block.height);
        },
        .quadrants => |bits| for (0..4) |i| {
            if (bits & (@as(u4, 1) << @intCast(i)) != 0) try fill(f, cell, color, x + @as(f32, @floatFromInt(i % 2)) * w / 2, y + @as(f32, @floatFromInt(i / 2)) * h / 2, w / 2, h / 2);
        },
    }
}

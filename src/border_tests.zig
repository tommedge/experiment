const std = @import("std");
const t = std.testing;
const ui = @import("root.zig");
const g = ui.geometry;

test "Yoga reserves snapped border widths inside the border box at each scale" {
    for ([_]f32{ 1, 2, 1.5 }) |scale| {
        var layout = try ui.layout.Layout.init(t.allocator, scale);
        defer layout.deinit();
        const widths = g.Edges{ .left = 0.25, .top = 1.25, .right = 2.5, .bottom = 3 };
        const snapped = try widths.snapped(scale);
        const child = try layout.request(.{ .grow = 1 }, &.{});
        const root = try layout.request(.{ .width = .{ .px = 100 }, .height = .{ .px = 60 }, .padding = .all(8), .border_widths = widths }, &.{child});
        layout.compute(root, .{ .width = 100, .height = 60 });
        const bounds = layout.bounds(child);
        try t.expectApproxEqAbs(8 + snapped.left, bounds.origin.x, 0.001);
        try t.expectApproxEqAbs(8 + snapped.top, bounds.origin.y, 0.001);
        try t.expectApproxEqAbs(100 - 16 - snapped.left - snapped.right, bounds.size.width, 0.001);
        try t.expectApproxEqAbs(60 - 16 - snapped.top - snapped.bottom, bounds.size.height, 0.001);
        try t.expectEqual(snapped.left, ui.layout.c.YGNodeLayoutGetBorder(root, ui.layout.c.YGEdgeLeft));
    }
    try t.expectEqualDeep(g.Edges.all(0.5), try g.Edges.all(0.25).snapped(2));
    try t.expectEqualDeep(g.Edges.all(1), try g.Edges.all(1.25).snapped(2)); // 2.5 device pixels ties toward zero.
    try t.expectEqualDeep(g.Edges{}, try (g.Edges{}).snapped(2));
    var layout = try ui.layout.Layout.init(t.allocator, 1);
    defer layout.deinit();
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |invalid| {
        try t.expectError(error.InvalidBorderWidth, layout.request(.{ .border_widths = .all(invalid) }, &.{}));
    }
    try t.expectEqual(@as(usize, 0), layout.nodes.items.len);
}

test "translucent border strips do not overlap or paint the interior" {
    var scene: ui.scene.Scene = .{};
    defer scene.deinit(t.allocator);
    const bounds = g.Bounds{ .origin = .{ .x = 3, .y = 4 }, .size = .{ .width = 12, .height = 10 } };
    const widths = g.Edges{ .left = 2, .top = 1, .right = 3, .bottom = 2 };
    try scene.border(t.allocator, .{ .bounds = bounds, .widths = widths, .color = .{ .r = 1, .a = 0.5 }, .clip = bounds });
    try t.expectEqual(@as(usize, 4), scene.primitives.items.len);
    const interior = bounds.inset(widths);
    for (0..10) |y| for (0..12) |x| {
        const point = g.Point{ .x = bounds.origin.x + @as(f32, @floatFromInt(x)) + 0.5, .y = bounds.origin.y + @as(f32, @floatFromInt(y)) + 0.5 };
        var coverage: usize = 0;
        for (scene.primitives.items) |primitive| {
            try t.expectEqual(@as(f32, 0.5), primitive.quad.color.a);
            if (primitive.quad.bounds.contains(point)) coverage += 1;
        }
        try t.expectEqual(@as(usize, if (interior.contains(point)) 0 else 1), coverage);
    };
    var oversized: ui.scene.Scene = .{};
    defer oversized.deinit(t.allocator);
    try oversized.border(t.allocator, .{ .bounds = bounds, .widths = .all(50), .color = .{}, .clip = bounds });
    try t.expectEqual(@as(usize, 1), oversized.primitives.items.len);
    try t.expectEqualDeep(bounds, oversized.primitives.items[0].quad.bounds);
    var invisible: ui.scene.Scene = .{};
    defer invisible.deinit(t.allocator);
    try invisible.border(t.allocator, .{ .bounds = bounds, .widths = .{}, .color = .{}, .clip = bounds });
    try invisible.border(t.allocator, .{ .bounds = bounds, .widths = widths, .color = .{ .a = 0 }, .clip = bounds });
    try invisible.border(t.allocator, .{ .bounds = bounds, .widths = widths, .color = .{}, .clip = interior });
    try t.expectEqual(@as(usize, 0), invisible.primitives.items.len);
}

/// Full-size fill used to compare cached and ordinary bordered containers.
const Fill = struct {
    renders: *usize,
    pub fn render(self: *const Fill, f: *ui.Frame, _: *ui.Context(Fill)) !ui.AnyElement {
        self.renders.* += 1;
        return f.div(.{ .id = 2, .style = .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .background = .{ .r = 0.7 } } });
    }
};
/// Independently varies the border and the ancestor clip to exercise cache keys.
const Box = struct {
    child: ui.Entity(Fill),
    cached: bool,
    clip_width: f32 = 100,
    border: f32 = 2,
    color: g.Color = .{ .g = 1, .a = 0.5 },
    pub fn render(self: *const Box, f: *ui.Frame, _: *ui.Context(Box)) !ui.AnyElement {
        const style = ui.Style{ .width = .{ .px = 100 }, .height = .{ .px = 60 }, .shrink = 0, .padding = .all(8), .border_widths = .all(self.border), .border_color = self.color, .background = .{ .b = 1 }, .clip = true };
        const child = if (self.cached) try f.cachedView(self.child, .{ .style = style }) else try f.div(.{ .style = style, .children = &.{try f.view(self.child)} });
        return f.div(.{ .id = 1, .style = .{ .width = .{ .px = self.clip_width }, .height = .{ .px = 60 }, .clip = true }, .children = &.{child} });
    }
    fn notify(_: *Box, cx: *ui.Context(Box)) !void {
        try cx.notify();
    }
    fn clipTo(self: *Box, width: f32, cx: *ui.Context(Box)) !void {
        self.clip_width = width;
        try cx.notify();
    }
    fn setBorder(self: *Box, width: f32, cx: *ui.Context(Box)) !void {
        self.border = width;
        try cx.notify();
    }
    fn recolor(self: *Box, cx: *ui.Context(Box)) !void {
        self.color = .{ .r = 1 };
        try cx.notify();
    }
};

test "cached border boxes match ordinary layout and retain the outer paint clip" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var a_renders: usize = 0;
    var b_renders: usize = 0;
    const a_child = try app.create(Fill{ .renders = &a_renders });
    const b_child = try app.create(Fill{ .renders = &b_renders });
    const a_root = try app.create(Box{ .child = a_child, .cached = true });
    const b_root = try app.create(Box{ .child = b_child, .cached = false });
    var a = try ui.Window.init(&app, a_root, .{ .width = 100, .height = 60 }, 1);
    defer a.deinit();
    var b = try ui.Window.init(&app, b_root, a.size, 1);
    defer b.deinit();
    _ = try a.drawIfNeeded();
    _ = try b.drawIfNeeded();
    try t.expectEqualDeep(a.renderer.backend.scene.primitives.items, b.renderer.backend.scene.primitives.items);
    const fill = a.renderer.backend.scene.primitives.items[5].quad;
    try t.expectEqualDeep(g.Bounds{ .origin = .{ .x = 10, .y = 10 }, .size = .{ .width = 80, .height = 40 } }, fill.bounds);
    try t.expectEqualDeep(g.Bounds{ .origin = .{ .x = 2, .y = 2 }, .size = .{ .width = 96, .height = 56 } }, fill.clip);
    try t.expectEqual(@as(?u64, 1), a.hitTest(.{ .x = 1, .y = 20 }));
    try t.expectEqual(@as(?u64, 2), a.hitTest(.{ .x = 11, .y = 20 }));
    try a_root.update(Box.notify);
    _ = try a.drawIfNeeded();
    try t.expectEqual(@as(usize, 1), a_renders);
    try a_root.update(Box.recolor);
    _ = try a.drawIfNeeded();
    try t.expectEqual(@as(usize, 2), a_renders);
    try b_root.update(Box.recolor);
    _ = try b.drawIfNeeded();
    for ([_]f32{ 2, 1 }) |width| {
        try app.updateWith(a_root, width, Box.clipTo);
        try app.updateWith(b_root, width, Box.clipTo);
        _ = try a.drawIfNeeded();
        _ = try b.drawIfNeeded();
        try t.expectEqualDeep(a.renderer.backend.scene.primitives.items, b.renderer.backend.scene.primitives.items);
        try t.expectEqual(width, a.renderer.backend.scene.primitives.items[0].quad.clip.size.width);
    }
    try t.expectEqual(@as(usize, 4), a_renders);
    const previous = a.inspect().?;
    try app.updateWith(a_root, @as(f32, -1), Box.setBorder);
    try t.expectError(error.InvalidBorderWidth, a.drawIfNeeded());
    try t.expect(a.inspect().? == previous and a.needsDraw());
    try app.updateWith(a_root, @as(f32, 1), Box.setBorder);
    _ = try a.drawIfNeeded();
}

test "bordered text measures its content width and aligns its baseline including borders" {
    // Bordered and plain text share a row baseline despite different outer insets.
    const TextRow = struct {
        pub fn render(_: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            const bordered = try f.text("aa aa", .{ .id = 9, .wrap = true, .style = .{ .font_size = 10 }, .layout_style = .{
                .width = .{ .px = 34 },
                .shrink = 0,
                .padding = .{ .left = 3, .right = 3, .top = 4, .bottom = 2 },
                .border_widths = .all(2),
                .border_color = .{ .r = 1 },
                .background = .{},
                .clip = true,
            } });
            return f.div(.{ .style = .{ .align_items = .baseline }, .children = &.{ bordered, try f.text("b", .{ .style = .{ .font_size = 10 } }) } });
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const backend = try ui.text.stub.create(t.allocator);
    const fonts = ui.TextSystem.create(t.allocator, backend) catch |err| {
        backend.deinit();
        return err;
    };
    defer fonts.release();
    app.setTextSystem(fonts);
    const root = try app.create(TextRow{});
    var window = try ui.Window.init(&app, root, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try t.expectEqualDeep(g.Size{ .width = 34, .height = 30 }, window.hitboxes.items[0].bounds.size);
    const primitives = window.renderer.backend.scene.primitives.items;
    const first = primitives[5].glyph;
    try t.expectEqualDeep(g.Point{ .x = 5, .y = 14 }, first.position);
    try t.expectEqual(@as(f32, 24), primitives[8].glyph.position.y);
    try t.expectEqual(first.position.y, primitives[primitives.len - 1].glyph.position.y);
    try t.expectEqualDeep(g.Bounds{ .origin = .{ .x = 2, .y = 2 }, .size = .{ .width = 30, .height = 26 } }, first.clip);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var app = ui.App.init(allocator);
    defer app.deinit();
    var renders: usize = 0;
    const child = try app.create(Fill{ .renders = &renders });
    const root = try app.create(Box{ .child = child, .cached = true });
    var window = try ui.Window.init(&app, root, .{ .width = 100, .height = 60 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try root.update(Box.notify);
    _ = try window.drawIfNeeded();
    try app.updateWith(root, @as(f32, 3), Box.setBorder);
    _ = try window.drawIfNeeded();
}
test "border construction and cached replay clean up on allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, allocationScenario, .{});
}

const std = @import("std");
const t = std.testing;
const ui = @import("root.zig");
const g = ui.geometry;

test "corner radii are validated and clamped without changing Yoga measurements" {
    var layout = try ui.layout.Layout.init(t.allocator, 1);
    defer layout.deinit();
    const child = try layout.request(.{ .grow = 1 }, &.{});
    const root = try layout.request(.{ .width = .{ .px = 100 }, .height = .{ .px = 60 }, .padding = .all(8), .border_widths = .all(2), .corner_radii = .all(100) }, &.{child});
    layout.compute(root, .{ .width = 100, .height = 60 });
    try t.expectEqualDeep(g.Bounds{ .origin = .{ .x = 10, .y = 10 }, .size = .{ .width = 80, .height = 40 } }, layout.bounds(child));
    var scene: ui.scene.Scene = .{};
    defer scene.deinit(t.allocator);
    try scene.box(t.allocator, .{ .bounds = layout.bounds(root), .clip = layout.bounds(root), .color = .{ .b = 1, .a = 0.5 }, .border_color = .{ .r = 1, .a = 0.5 }, .border_widths = .all(2), .corner_radii = .{ .top_left = 100, .top_right = 8, .bottom_left = 2 } });
    try t.expectEqual(@as(usize, 1), scene.primitives.items.len);
    const quad = scene.primitives.items[0].quad;
    try t.expectEqualDeep(g.Corners{ .top_left = 30, .top_right = 8, .bottom_left = 2 }, quad.corner_radii);
    try t.expectEqual(@as(f32, 0.5), quad.color.a);
    try t.expectEqual(@as(f32, 0.5), quad.border_color.a);
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |invalid| {
        try t.expectError(error.InvalidCornerRadius, layout.request(.{ .corner_radii = .all(invalid) }, &.{}));
        try t.expectError(error.InvalidCornerRadius, scene.quad(t.allocator, .{ .bounds = quad.bounds, .clip = quad.clip, .color = .{}, .corner_radii = .all(invalid) }));
    }
}

/// Empty-content view lets tests observe the owning box's unified paint primitive.
const Content = struct {
    renders: *usize,
    pub fn render(self: *const Content, f: *ui.Frame, _: *ui.Context(Content)) !ui.AnyElement {
        self.renders.* += 1;
        return f.div(.{ .id = 2, .style = .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 } } });
    }
};
/// Switchable cache boundary for verifying radius changes and replay ownership.
const Container = struct {
    content: ui.Entity(Content),
    cached: bool,
    radius: f32 = 12,
    pub fn render(self: *const Container, f: *ui.Frame, _: *ui.Context(Container)) !ui.AnyElement {
        const style = ui.Style{ .width = .{ .px = 100 }, .height = .{ .px = 60 }, .padding = .all(8), .clip = true, .border_widths = .{ .left = 4, .top = 2, .right = 1, .bottom = 0 }, .border_color = .{ .r = 1 }, .corner_radii = .all(self.radius), .background = .{ .b = 1 } };
        return if (self.cached) f.cachedView(self.content, .{ .style = style }) else f.div(.{ .style = style, .children = &.{try f.view(self.content)} });
    }
    fn notify(_: *Container, cx: *ui.Context(Container)) !void {
        try cx.notify();
    }
    fn radiusTo(self: *Container, value: f32, cx: *ui.Context(Container)) !void {
        self.radius = value;
        try cx.notify();
    }
};
test "rounded cached and ordinary boxes agree; radius changes invalidate cache transactionally" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var renders: usize = 0;
    const content = try app.create(Content{ .renders = &renders });
    const cached = try app.create(Container{ .content = content, .cached = true });
    const normal = try app.create(Container{ .content = content, .cached = false });
    var a = try ui.Window.init(&app, cached, .{ .width = 100, .height = 60 }, 2);
    defer a.deinit();
    var b = try ui.Window.init(&app, normal, a.size, 2);
    defer b.deinit();
    _ = try a.drawIfNeeded();
    _ = try b.drawIfNeeded();
    try t.expectEqualDeep(b.renderer.backend.scene.primitives.items, a.renderer.backend.scene.primitives.items);
    const before = renders;
    for (0..3) |_| {
        try cached.update(Container.notify);
        _ = try a.drawIfNeeded();
    }
    try t.expectEqual(before, renders);
    try app.updateWith(cached, @as(f32, 2), Container.radiusTo);
    _ = try a.drawIfNeeded();
    try t.expectEqual(before + 1, renders);
    try t.expectEqualDeep(g.Corners.all(2), a.inspect().?.scene[0].quad.corner_radii);
    const previous = a.inspect().?;
    try app.updateWith(cached, @as(f32, -1), Container.radiusTo);
    try t.expectError(error.InvalidCornerRadius, a.drawIfNeeded());
    try t.expect(a.inspect().? == previous);
}

test "rounded border-only helper and text backgrounds carry analytic quad data" {
    var scene: ui.scene.Scene = .{};
    defer scene.deinit(t.allocator);
    const bounds = g.Bounds{ .size = .{ .width = 40, .height = 30 } };
    try scene.border(t.allocator, .{ .bounds = bounds, .clip = bounds, .widths = .all(2), .color = .{ .g = 1 }, .corner_radii = .all(10) });
    try t.expectEqual(@as(usize, 1), scene.primitives.items.len);
    try t.expectEqual(@as(f32, 0), scene.primitives.items[0].quad.color.a);
    // Text uses the same box painter while retaining rectangular layout and clips.
    const Label = struct {
        pub fn render(_: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            return f.text("a", .{ .style = .{ .font_size = 10 }, .layout_style = .{ .width = .{ .px = 40 }, .height = .{ .px = 30 }, .padding = .all(4), .border_widths = .all(2), .border_color = .{ .r = 1 }, .corner_radii = .all(8), .background = .{ .b = 1 } } });
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
    const root = try app.create(Label{});
    var window = try ui.Window.init(&app, root, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    const primitives = window.inspect().?.scene;
    try t.expectEqual(@as(usize, 2), primitives.len);
    try t.expectEqualDeep(g.Corners.all(8), primitives[0].quad.corner_radii);
    try t.expectEqualDeep(g.Point{ .x = 6, .y = 14 }, primitives[1].glyph.position);
}

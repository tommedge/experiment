const std = @import("std");
const t = std.testing;
const ui = @import("root.zig");
const g = ui.geometry;

test "invisible quad fills are omitted while transparent-fill outlines remain visible" {
    var scene: ui.scene.Scene = .{};
    defer scene.deinit(t.allocator);
    const bounds = g.Bounds{ .size = .{ .width = 40, .height = 40 } };
    try scene.quad(t.allocator, .{ .bounds = bounds, .clip = bounds, .color = .{ .r = 1, .a = 0 } });
    try scene.quad(t.allocator, .{ .bounds = bounds, .clip = bounds, .color = g.Color.transparent, .corner_radii = .all(8), .border_color = .{ .r = 1 } });
    try t.expectEqual(@as(usize, 0), scene.primitives.items.len);
    try scene.quad(t.allocator, .{ .bounds = bounds, .clip = bounds, .color = g.Color.transparent, .corner_radii = .all(8), .border_color = .{ .r = 1, .a = 0.5 }, .border_widths = .all(2) });
    try t.expectEqual(@as(usize, 1), scene.primitives.items.len);
    try t.expect(!scene.primitives.items[0].quad.isTransparent());
    try t.expectEqual(@as(f32, 0), scene.primitives.items[0].quad.color.a);
}

/// Reactive alpha value; instrumentation distinguishes rebuilding from replay.
const Overlay = struct {
    alpha: f32 = 0.5,
    renders: *usize,
    pub fn render(self: *const Overlay, f: *ui.Frame, _: *ui.Context(Overlay)) !ui.AnyElement {
        self.renders.* += 1;
        return f.div(.{ .id = 7, .style = .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .corner_radii = .all(8), .background = .{ .r = 1, .a = self.alpha } } });
    }
    fn setAlpha(self: *Overlay, alpha: f32, cx: *ui.Context(Overlay)) !void {
        self.alpha = alpha;
        try cx.notify();
    }
};
/// Caches the overlay independently of the parent's notifications.
const Host = struct {
    overlay: ui.Entity(Overlay),
    pub fn render(self: *const Host, f: *ui.Frame, _: *ui.Context(Host)) !ui.AnyElement {
        return f.cachedView(self.overlay, .{ .style = .{ .width = .{ .px = 60 }, .height = .{ .px = 40 } } });
    }
    fn notify(_: *Host, cx: *ui.Context(Host)) !void {
        try cx.notify();
    }
};
test "cached transparent quads preserve straight alpha and independent hitboxes" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var renders: usize = 0;
    const overlay = try app.create(Overlay{ .renders = &renders });
    const root = try app.create(Host{ .overlay = overlay });
    var window = try ui.Window.init(&app, root, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    for (0..3) |_| {
        try root.update(Host.notify);
        _ = try window.drawIfNeeded();
    }
    try t.expectEqual(@as(usize, 1), renders);
    const quad = window.renderer.backend.scene.primitives.items[0].quad;
    try t.expectEqual(@as(f32, 1), quad.color.r); // Scene colors remain unpremultiplied.
    try t.expectEqual(@as(f32, 0.5), quad.color.a);
    try app.updateWith(overlay, @as(f32, 0), Overlay.setAlpha);
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 0), window.renderer.backend.scene.primitives.items.len);
    try t.expectEqual(@as(?u64, 7), window.hitTest(.{ .x = 10, .y = 10 }));
    try root.update(Host.notify);
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 2), renders);
    try t.expectEqual(@as(?u64, 7), window.hitTest(.{ .x = 10, .y = 10 }));
    try app.updateWith(overlay, @as(f32, 1), Overlay.setAlpha);
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(f32, 1), window.renderer.backend.scene.primitives.items[0].quad.color.a);
}

const std = @import("std");
const ui = @import("zigui");

const Changed = struct { value: u32 };
const Counter = struct {
    value: u32 = 1,
    fn increment(self: *Counter, cx: *ui.Context(Counter)) !void {
        self.value += 1;
        try cx.notify();
        try cx.emit(Changed{ .value = self.value });
    }
    pub fn render(self: *const Counter, f: *ui.Frame, _: *ui.Context(Counter)) !ui.AnyElement {
        const bar = try f.div(.{ .id = 1, .style = .{
            .width = .{ .px = @as(f32, @floatFromInt(self.value)) * 40 },
            .height = .{ .px = 40 },
            .background = .{ .r = 0.2, .g = 0.6, .b = 0.9 },
        } });
        return f.div(.{ .style = .{ .padding = .{ .left = 12, .top = 12 }, .gap = 8 }, .children = &.{bar} });
    }
};
fn onChanged(_: *void, _: ui.Entity(Counter), event: *const Changed, _: *ui.App) void {
    std.debug.print("counter emitted Changed({d})\n", .{event.value});
}
pub fn main() !void {
    var app = ui.App.init(std.heap.page_allocator);
    defer app.deinit();
    const counter = try app.create(Counter{});
    var subscription = try app.subscribe(counter, Changed, void, {}, onChanged);
    defer subscription.deinit();
    var window = try ui.Window.init(&app, counter, .{ .width = 640, .height = 480 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try counter.update(Counter.increment);
    _ = try window.drawIfNeeded();
    std.debug.print("stub presented {d} frames; bar width: {d}; idle redraw: {}\n", .{
        window.renderer.backend.presented_frames,
        window.renderer.backend.scene.primitives.items[0].quad.bounds.size.width,
        try window.drawIfNeeded(),
    });
}

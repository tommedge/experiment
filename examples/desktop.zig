const std = @import("std");
const ui = @import("zigui");
const Counter = struct {
    value: u32 = 1,
    pub fn render(self: *const Counter, f: *ui.Frame, _: *ui.Context(Counter)) !ui.AnyElement {
        const bar = try f.div(.{ .id = 1, .style = .{ .width = .{ .px = @as(f32, @floatFromInt(self.value)) * 40 }, .height = .{ .px = 60 }, .background = .{ .r = 0.1, .g = 0.5, .b = 0.9 } } });
        return f.div(.{ .style = .{ .padding = .{ .left = 24, .top = 24 }, .clip = true }, .children = &.{bar} });
    }
    fn increment(self: *Counter, cx: *ui.Context(Counter)) !void {
        self.value = self.value % 12 + 1;
        try cx.notify();
    }
};
const Controller = struct {
    counter: ui.Entity(Counter),
    platform: *ui.Platform,
    fn dispatch(ptr: *anyopaque, event: ui.input.PlatformInput, target: ?u64) ui.input.DispatchEventResult {
        const self: *Controller = @ptrCast(@alignCast(ptr));
        const increment = switch (event) {
            .mouse_down => |e| target == 1 and e.button == .left,
            .key_down => |e| blk: {
                if (e.modifiers.command and std.mem.eql(u8, e.key, "q")) {
                    self.platform.quit();
                    return .{ .handled = true };
                }
                break :blk std.mem.eql(u8, e.key, "space");
            },
            else => false,
        };
        if (increment) self.counter.update(Counter.increment) catch |err| std.log.err("update: {s}", .{@errorName(err)});
        return .{ .handled = increment };
    }
};
pub fn main(init: std.process.Init) !void {
    var app = ui.App.init(std.heap.c_allocator);
    defer app.deinit();
    var platform = try ui.Platform.init(app.allocator);
    defer platform.deinit();
    app.wakeup = .{ .context = &platform, .schedule = ui.Platform.schedule };
    defer app.wakeup = null;
    const counter = try app.create(Counter{});
    const window = try ui.NativeWindow.create(&app, platform, counter, .{ .title = "zigui — click the bar or press Space" });
    defer window.destroy();
    var controller = Controller{ .counter = counter, .platform = &platform };
    window.on_input = .{ .context = &controller, .dispatch = Controller.dispatch };
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--smoke")) {
        _ = try window.content.drawIfNeeded();
        try counter.update(Counter.increment);
        _ = try window.content.drawIfNeeded();
        std.debug.print("Metal presented two frames at scale {d}; hit target: {?d}\n", .{ window.content.scale, window.content.hitTest(.{ .x = 30, .y = 30 }) });
        return;
    }
    platform.run();
    if (window.last_error) |err| return err;
}

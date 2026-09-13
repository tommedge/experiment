const std = @import("std");
const t = std.testing;
const ui = @import("root.zig");
const Choose = struct { value: u32 };
const Log = struct {
    calls: [64]u8 = undefined,
    len: usize = 0,
    stop: ?u8 = null,
    handle_only: bool = false,
    chosen: u32 = 0,
    created: usize = 0,
    destroyed: usize = 0,
    window: ?*ui.Window = null,
    fn reset(self: *Log) void {
        self.len = 0;
        self.stop = null;
        self.handle_only = false;
    }
};
const Capture = struct {
    log: *Log,
    label: u8,
    pub fn deinit(self: *Capture) void {
        self.log.destroyed += 1;
    }
    fn input(self: *Capture, _: ui.input.PlatformInput, phase: ui.DispatchPhase, cx: *ui.EventContext) !void {
        self.log.calls[self.log.len] = self.label;
        self.log.len += 1;
        if (self.label == 1 and phase == .capture) {
            try t.expectError(error.FrameDuringUpdate, self.log.window.?.drawIfNeeded());
            try t.expectError(error.InputDuringUpdate, self.log.window.?.dispatchAction(Choose{ .value = 0 }));
        }
        if (self.log.stop == self.label) cx.stopPropagation();
        if (self.log.handle_only and self.label == 3) cx.handle();
    }
    fn action(self: *Capture, value: *const Choose, phase: ui.DispatchPhase, cx: *ui.EventContext) !void {
        if (phase != .bubble) return;
        self.log.chosen = value.value;
        cx.stopPropagation();
    }
};
const Routing = struct {
    log: *Log,
    focus: ui.FocusHandle,
    fn listener(self: *const Routing, f: *ui.Frame, label: u8) !ui.dispatch.Listener {
        const listener_value = try f.inputListener(Capture{ .log = self.log, .label = label }, Capture.input);
        self.log.created += 1;
        return listener_value;
    }
    pub fn render(self: *const Routing, f: *ui.Frame, _: *ui.Context(Routing)) !ui.AnyElement {
        const action = try f.actionListener(Choose, Capture{ .log = self.log, .label = 3 }, Capture.action);
        self.log.created += 1;
        const target = try f.div(.{ .id = 3, .focus = self.focus, .listeners = &.{ try self.listener(f, 3), action } });
        const editor = try f.div(.{ .key_context = "Editor", .listeners = &.{try self.listener(f, 2)}, .children = &.{target} });
        return f.div(.{
            .key_context = "Workspace",
            .listeners = &.{try self.listener(f, 1)},
            .children = &.{editor},
            .bindings = &.{
                try f.bindKey("space", .{}, "Workspace", Choose{ .value = 1 }),
                try f.bindKey("space", .{}, "Editor", Choose{ .value = 2 }),
                try f.bindKey("space", .{ .shift = true }, "Editor", Choose{ .value = 3 }),
                try f.bindKey("space", .{}, "Absent", Choose{ .value = 4 }),
            },
        });
    }
};
const Host = struct {
    child: ui.Entity(Routing),
    show: bool = true,
    pub fn render(self: *const Host, f: *ui.Frame, _: *ui.Context(Host)) !ui.AnyElement {
        return if (self.show) f.cachedView(self.child, .{ .style = .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } } }) else f.div(.{});
    }
    fn notify(_: *Host, cx: *ui.Context(Host)) !void {
        try cx.notify();
    }
    fn hide(self: *Host, cx: *ui.Context(Host)) !void {
        self.show = false;
        try cx.notify();
    }
};
test "focused capture and bubble dispatch, context precedence, typed actions and capture lifetime survive replay" {
    var log: Log = .{};
    {
        var app = ui.App.init(t.allocator);
        defer app.deinit();
        const focus = app.newFocusHandle();
        const routing = try app.create(Routing{ .log = &log, .focus = focus });
        const root = try app.create(Host{ .child = routing });
        var window = try ui.Window.init(&app, root, .{ .width = 200, .height = 100 }, 1);
        defer window.deinit();
        log.window = &window;
        _ = try window.drawIfNeeded();
        try window.focus(focus);
        _ = try window.drawIfNeeded();
        const created = log.created;
        const destroyed = log.destroyed;
        for (0..3) |_| {
            try root.update(Host.notify);
            _ = try window.drawIfNeeded();
        }
        try t.expectEqual(created, log.created);
        try t.expectEqual(destroyed, log.destroyed);
        const key_up = ui.input.PlatformInput{ .key_up = .{ .key_code = 49, .key = "space", .modifiers = .{} } };
        try t.expect(!(try window.dispatchInput(key_up)).handled);
        try t.expectEqualSlices(u8, &.{ 1, 2, 3, 3, 2, 1 }, log.calls[0..log.len]);
        log.reset();
        log.stop = 2;
        try t.expect((try window.dispatchInput(key_up)).handled);
        try t.expectEqualSlices(u8, &.{ 1, 2 }, log.calls[0..log.len]);
        log.reset();
        log.handle_only = true;
        try t.expect((try window.dispatchInput(key_up)).handled);
        try t.expectEqualSlices(u8, &.{ 1, 2, 3, 3, 2, 1 }, log.calls[0..log.len]);
        log.reset();
        try t.expect((try window.dispatchInput(.{ .key_down = key_up.key_up })).handled);
        try t.expectEqual(@as(u32, 2), log.chosen);
        log.reset();
        try t.expect((try window.dispatchInput(.{ .key_down = .{ .key_code = 49, .key = "space", .modifiers = .{ .shift = true } } })).handled);
        try t.expectEqual(@as(u32, 3), log.chosen);
        log.reset();
        try t.expect((try window.dispatchAction(Choose{ .value = 9 })).handled);
        try t.expectEqual(@as(u32, 9), log.chosen);
        try root.update(Host.hide);
        _ = try window.drawIfNeeded();
        try t.expect(window.focused == null);
        try t.expectEqual(log.created, log.destroyed);
        try t.expect(!(try window.dispatchInput(key_up)).handled);
    }
    try t.expectEqual(log.created, log.destroyed);
}

const TextCapture = struct {
    value: [4]u8 = .{ 't', 'e', 's', 't' },
    pub fn selectedRange(_: *TextCapture) ?ui.input.TextRange {
        return .{ .location = 2, .length = 0 };
    }
    pub fn markedRange(_: *TextCapture) ?ui.input.TextRange {
        return null;
    }
    pub fn textForRange(self: *TextCapture, range: ui.input.TextRange) ?[]const u8 {
        if (range.location > self.value.len or range.length > self.value.len - range.location) return null;
        return self.value[range.location..][0..range.length];
    }
    pub fn boundsForRange(_: *TextCapture, _: ui.input.TextRange) ?ui.geometry.Bounds {
        return .{ .origin = .{ .x = 10, .y = 10 }, .size = .{ .width = 1, .height = 20 } };
    }
    pub fn characterIndex(_: *TextCapture, _: ui.geometry.Point) ?usize {
        return 2;
    }
};
test "focused text provider capture survives cache hits and clears with its focus node" {
    const TextView = struct {
        focus: ui.FocusHandle,
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            return f.div(.{ .focus = self.focus, .text_input = try f.textInputHandler(TextCapture{}, TextCapture) });
        }
    };
    const TextHost = struct {
        child: ui.Entity(TextView),
        show: bool = true,
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            return if (self.show) f.cachedView(self.child, .{ .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 40 } } }) else f.div(.{});
        }
        fn notify(_: *@This(), cx: *ui.Context(@This())) !void {
            try cx.notify();
        }
        fn hide(self: *@This(), cx: *ui.Context(@This())) !void {
            self.show = false;
            try cx.notify();
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const focus = app.newFocusHandle();
    const child = try app.create(TextView{ .focus = focus });
    const root = try app.create(TextHost{ .child = child });
    var window = try ui.Window.init(&app, root, .{ .width = 200, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try window.focus(focus);
    _ = try window.drawIfNeeded();
    for (0..3) |_| {
        try root.update(TextHost.notify);
        _ = try window.drawIfNeeded();
    }
    const handler = window.focusedTextInput().?;
    try t.expectEqual(@as(usize, 2), handler.selected_range(handler.context).?.location);
    try t.expectEqualStrings("test", handler.text_for_range(handler.context, .{ .location = 0, .length = 4 }).?);
    try root.update(TextHost.hide);
    _ = try window.drawIfNeeded();
    try t.expect(window.focusedTextInput() == null);
}

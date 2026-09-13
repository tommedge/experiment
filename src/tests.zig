const std = @import("std");
const ui = @import("root.zig");
const t = std.testing;

test "Yoga computes flex grow, padding, gap and absolute descendant bounds" {
    var layout = try ui.layout.Layout.init(t.allocator, 1);
    defer layout.deinit();
    const a = try layout.request(.{ .grow = 1, .basis = .{ .px = 0 } }, &.{});
    const b = try layout.request(.{ .grow = 2, .basis = .{ .px = 0 } }, &.{});
    const root = try layout.request(.{ .padding = .{ .left = 10, .right = 10, .top = 5 }, .gap = 10 }, &.{ a, b });
    layout.compute(root, .{ .width = 330, .height = 100 });
    try t.expectEqual(@as(f32, 100), layout.bounds(a).size.width);
    try t.expectEqual(@as(f32, 200), layout.bounds(b).size.width);
    try t.expectEqual(@as(f32, 120), layout.bounds(b).origin.x);
    try t.expectEqual(@as(f32, 5), layout.bounds(b).origin.y);
}

const Changed = struct { value: u32 };
const Other = struct { value: u32 };
const Model = struct {
    value: u32 = 10,
    pub fn render(self: *const Model, f: *ui.Frame, _: *ui.Context(Model)) !ui.AnyElement {
        return f.div(.{ .id = 7, .style = .{
            .width = .{ .px = @floatFromInt(self.value) },
            .height = .{ .px = 20 },
            .background = .{ .r = 1 },
        } });
    }
    fn change(self: *Model, cx: *ui.Context(Model)) !void {
        self.value += 10;
        try cx.notify();
        try cx.notify();
        try cx.emit(Changed{ .value = self.value });
    }
    fn silent(self: *Model, _: *ui.Context(Model)) !void {
        self.value += 1;
    }
};

test "notify coalesces, events are typed and deferred until state is unborrowed" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const model = try app.create(Model{});
    const Counts = struct {
        observed: usize = 0,
        events: usize = 0,
        fn observe(p: **@This(), source: ui.Entity(Model), _: *ui.App) void {
            p.*.observed += 1;
            t.expectEqual(@as(u32, 20), (source.read() catch unreachable).value) catch unreachable;
        }
        fn event(p: **@This(), source: ui.Entity(Model), e: *const Changed, _: *ui.App) void {
            p.*.events += 1;
            t.expectEqual(e.value, (source.read() catch unreachable).value) catch unreachable;
        }
        fn wrong(_: *void, _: ui.Entity(Model), _: *const Other, _: *ui.App) void {
            @panic("wrong event type");
        }
    };
    var counts = Counts{};
    var observer = try app.observe(model, *Counts, &counts, Counts.observe);
    defer observer.deinit();
    var subscription = try app.subscribe(model, Changed, *Counts, &counts, Counts.event);
    defer subscription.deinit();
    var wrong = try app.subscribe(model, Other, void, {}, Counts.wrong);
    defer wrong.deinit();
    try model.update(Model.change);
    try t.expectEqual(@as(usize, 1), counts.observed);
    try t.expectEqual(@as(usize, 1), counts.events);
    try model.update(Model.silent);
    try t.expectEqual(@as(usize, 1), counts.observed);
    subscription.deinit();
    try app.emit(model, Changed{ .value = 21 });
    try app.flush();
    try t.expectEqual(@as(usize, 1), counts.events);
}

test "callback cancellation, insertion, nested events and detach are safe" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const model = try app.create(Model{});
    const State = struct {
        first: ui.Subscription = undefined,
        second: ui.Subscription = undefined,
        calls: usize = 0,
        fn firstCall(p: **@This(), source: ui.Entity(Model), _: *const Changed, a: *ui.App) void {
            const s = p.*;
            s.first.deinit();
            s.second.deinit();
            var sub = a.subscribe(source, Changed, *@This(), s, later) catch unreachable;
            sub.detach();
            a.emit(source, Changed{ .value = 2 }) catch unreachable;
            a.flush() catch unreachable;
        }
        fn secondCall(_: **@This(), _: ui.Entity(Model), _: *const Changed, _: *ui.App) void {
            @panic("cancelled callback ran");
        }
        fn later(p: **@This(), _: ui.Entity(Model), e: *const Changed, _: *ui.App) void {
            t.expectEqual(@as(u32, 2), e.value) catch unreachable;
            p.*.calls += 1;
        }
    };
    var state = State{};
    state.first = try app.subscribe(model, Changed, *State, &state, State.firstCall);
    state.second = try app.subscribe(model, Changed, *State, &state, State.secondCall);
    try app.emit(model, Changed{ .value = 1 });
    try app.flush();
    try t.expectEqual(@as(usize, 1), state.calls);
    try app.emit(model, Changed{ .value = 2 });
    try app.flush();
    try t.expectEqual(@as(usize, 2), state.calls);
}

test "context subscriptions update owner and stop on owner release" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const source = try app.create(Model{});
    const Owner = struct {
        source: ui.Entity(Model),
        total: u32 = 0,
        fn setup(self: *@This(), cx: *ui.Context(@This())) !void {
            var sub = try cx.subscribe(self.source, Changed, void, {}, event);
            sub.detach();
            var obs = try cx.observe(self.source, void, {}, observed);
            obs.detach();
        }
        fn event(self: *@This(), _: ui.Entity(Model), e: *const Changed, _: *void, cx: *ui.Context(@This())) void {
            self.total += e.value;
            cx.notify() catch unreachable;
        }
        fn observed(self: *@This(), _: ui.Entity(Model), _: *void, _: *ui.Context(@This())) void {
            self.total += 1;
        }
    };
    const owner = try app.create(Owner{ .source = source });
    const weak = owner.downgrade();
    try owner.update(Owner.setup);
    try source.update(Model.change);
    try t.expectEqual(@as(u32, 21), (try owner.read()).total);
    try app.destroy(owner);
    try t.expect(weak.upgrade() == null);
    try t.expectError(error.EntityReleased, owner.read());
    try source.update(Model.change);
    const replacement = try app.create(Owner{ .source = source });
    try t.expect(replacement.id != owner.id);
}

test "borrow protection and failed updates still deliver queued effects" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const model = try app.create(Model{});
    const Callback = struct {
        fn call(_: *Model, cx: *ui.Context(Model)) !void {
            try t.expectError(error.EntityBorrowed, cx.entity.read());
            try t.expectError(error.EntityBorrowed, cx.app.destroy(cx.entity));
            try cx.notify();
            return error.Intentional;
        }
    };
    try t.expectError(error.Intentional, model.update(Callback.call));
    _ = try model.read();
    try t.expectEqual(@as(usize, 0), app.effects.items.len);
    try t.expectEqual(@as(u64, 1), app.revision(model.id).?);
    var other = ui.App.init(t.allocator);
    defer other.deinit();
    try t.expectError(error.WrongApp, other.read(model));
}

test "window redraw is explicit, dependency-scoped and resize driven" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const model = try app.create(Model{});
    const unrelated = try app.create(Model{});
    var window = try ui.Window.init(&app, model, .{ .width = 200, .height = 100 }, 1);
    defer window.deinit();
    try t.expect(try window.drawIfNeeded());
    try t.expectEqual(@as(?u64, 7), window.hitTest(.{ .x = 5, .y = 5 }));
    try t.expect(window.hitTest(.{ .x = 10, .y = 5 }) == null);
    try t.expect(!try window.drawIfNeeded());
    try unrelated.update(Model.change);
    try t.expect(!try window.drawIfNeeded());
    try model.update(Model.silent);
    try t.expect(!try window.drawIfNeeded());
    try model.update(Model.change);
    try t.expect(window.needsDraw());
    try t.expect(try window.drawIfNeeded());
    try t.expectEqual(@as(f32, 21), window.renderer.backend.scene.primitives.items[0].quad.bounds.size.width);
    try window.resize(.{ .width = 300, .height = 200 }, 2);
    try t.expect(try window.drawIfNeeded());
    try t.expectEqual(@as(f32, 2), window.renderer.backend.scale);
    try t.expectError(error.InvalidScale, window.resize(window.size, 0));
}

test "render reads track dependencies and replace them each successful frame" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const model = try app.create(Model{});
    const View = struct {
        model: ui.Entity(Model),
        show: bool = true,
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            return if (self.show) f.view(self.model) else f.div(.{});
        }
        fn hide(self: *@This(), cx: *ui.Context(@This())) !void {
            self.show = false;
            try cx.notify();
        }
    };
    const view = try app.create(View{ .model = model });
    var window = try ui.Window.init(&app, view, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try model.update(Model.change);
    try t.expect(try window.drawIfNeeded());
    try view.update(View.hide);
    _ = try window.drawIfNeeded();
    try model.update(Model.change);
    try t.expect(!try window.drawIfNeeded());
}

test "custom element phase states survive in order, and duplicate draws fail" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var f = try ui.Frame.init(&app, .{ .width = 100, .height = 100 }, 1);
    defer f.deinit();
    const Custom = struct {
        pub const RequestLayoutState = u32;
        pub const PrepaintState = u32;
        result: *u32,
        pub fn requestLayout(_: *@This(), frame: *ui.Frame) !ui.LayoutRequest(u32) {
            return .{ .id = try frame.layout.request(.{}, &.{}), .state = 40 };
        }
        pub fn prepaint(_: *@This(), _: *ui.Frame, b: ui.geometry.Bounds, state: *u32) !u32 {
            try t.expectEqual(@as(f32, 100), b.size.width);
            state.* += 1;
            return state.* + 1;
        }
        pub fn paint(self: *@This(), _: *ui.Frame, _: ui.geometry.Bounds, request: *u32, pre: *u32) !void {
            try t.expectEqual(@as(u32, 41), request.*);
            self.result.* = pre.*;
        }
    };
    var result: u32 = 0;
    const element = try f.element(Custom{ .result = &result });
    try t.expectError(error.InvalidPhase, element.paint(&f));
    try f.draw(element);
    try t.expectEqual(@as(u32, 42), result);
    try t.expectError(error.InvalidPhase, f.draw(element));
}

test "Yoga percentages, wrapping, min size and nested absolute position" {
    var l = try ui.layout.Layout.init(t.allocator, 1);
    defer l.deinit();
    const absolute = try l.request(.{ .absolute = true, .left = 7, .top = 9, .width = .{ .px = 4 }, .height = .{ .px = 5 } }, &.{});
    const a = try l.request(.{ .width = .{ .percent = 60 }, .height = .{ .px = 20 }, .shrink = 0 }, &.{absolute});
    const b = try l.request(.{ .width = .{ .px = 10 }, .min_width = 60, .height = .{ .px = 20 }, .shrink = 0 }, &.{});
    const root = try l.request(.{ .wrap = true, .padding = .{ .left = 10, .top = 10, .right = 10 }, .gap = 5 }, &.{ a, b });
    l.compute(root, .{ .width = 120, .height = 60 });
    try t.expectEqual(@as(f32, 60), l.bounds(a).size.width);
    try t.expectEqual(@as(f32, 60), l.bounds(b).size.width);
    try t.expect(l.bounds(b).origin.y > l.bounds(a).origin.y);
    try t.expectEqual(@as(f32, 17), l.bounds(absolute).origin.x);
    try t.expectEqual(@as(f32, 19), l.bounds(absolute).origin.y);
}

test "hidden subtrees and clipping affect both scene and hit testing" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var f = try ui.Frame.init(&app, .{ .width = 100, .height = 100 }, 1);
    defer f.deinit();
    const child = try f.div(.{ .id = 2, .style = .{ .width = .{ .px = 80 }, .height = .{ .px = 80 }, .shrink = 0, .background = .{} } });
    const hidden_child = try f.div(.{ .id = 3, .style = .{ .background = .{} } });
    const hidden = try f.div(.{ .id = 4, .style = .{ .hidden = true }, .children = &.{hidden_child} });
    const root = try f.div(.{ .style = .{ .width = .{ .px = 50 }, .height = .{ .px = 50 }, .clip = true }, .children = &.{ child, hidden } });
    try f.draw(root);
    try t.expectEqual(@as(usize, 1), f.hitboxes.items.len);
    try t.expectEqual(@as(f32, 50), f.hitboxes.items[0].bounds.size.width);
    try t.expectEqual(@as(usize, 1), f.scene.primitives.items.len);
    try t.expectEqual(@as(f32, 50), f.scene.primitives.items[0].quad.clip.size.width);
}

test "alternate backend failure preserves presented frame and retries" {
    const Failing = struct {
        stub: ui.renderer.Stub,
        fail: bool = false,
        pub fn init(a: std.mem.Allocator, size: ui.geometry.Size, scale: f32) !@This() {
            return .{ .stub = try .init(a, size, scale) };
        }
        pub fn deinit(self: *@This()) void {
            self.stub.deinit();
        }
        pub fn resize(self: *@This(), size: ui.geometry.Size, scale: f32) !void {
            try self.stub.resize(size, scale);
        }
        pub fn submit(self: *@This(), scene: *const ui.scene.Scene) !void {
            if (self.fail) return error.BackendUnavailable;
            try self.stub.submit(scene);
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const model = try app.create(Model{});
    var window = try ui.WindowWithRenderer(ui.renderer.GenericRenderer(Failing)).init(&app, model, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    window.renderer.backend.fail = true;
    try model.update(Model.change);
    try t.expectError(error.BackendUnavailable, window.drawIfNeeded());
    try t.expect(window.hitTest(.{ .x = 15, .y = 5 }) == null);
    try t.expectEqual(@as(usize, 1), window.renderer.backend.stub.presented_frames);
    try t.expect(window.needsDraw());
    window.renderer.backend.fail = false;
    try t.expect(try window.drawIfNeeded());
    try t.expectEqual(@as(?u64, 7), window.hitTest(.{ .x = 15, .y = 5 }));
}

fn allocationScenario(a: std.mem.Allocator) !void {
    var app = ui.App.init(a);
    defer app.deinit();
    const model = try app.create(Model{});
    const Handler = struct {
        fn call(_: *void, _: ui.Entity(Model), _: *const Changed, _: *ui.App) void {}
    };
    var sub = try app.subscribe(model, Changed, void, {}, Handler.call);
    defer sub.deinit();
    var window = try ui.Window.init(&app, model, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try model.update(Model.change);
    _ = try window.drawIfNeeded();
}
test "allocation failures release partial frames, entities and queued events" {
    try t.checkAllAllocationFailures(t.allocator, allocationScenario, .{});
}

test "nested updates flush at outer boundary and wake the host" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const Scheduler = struct {
        scheduled: usize = 0,
        fn schedule(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.scheduled += 1;
        }
    };
    var scheduler = Scheduler{};
    app.wakeup = .{ .context = &scheduler, .schedule = Scheduler.schedule };
    var calls: usize = 0;
    const inner = try app.create(Model{});
    const Outer = struct {
        inner: ui.Entity(Model),
        calls: *usize,
        fn change(self: *@This(), cx: *ui.Context(@This())) !void {
            try self.inner.update(Model.change);
            try t.expectEqual(@as(usize, 0), self.calls.*);
            try cx.notify();
        }
    };
    const outer = try app.create(Outer{ .inner = inner, .calls = &calls });
    const Capture = struct {
        outer: ui.Entity(Outer),
        calls: *usize,
        fn observe(self: *@This(), _: ui.Entity(Model), _: *ui.App) void {
            _ = self.outer.read() catch unreachable;
            self.calls.* += 1;
        }
    };
    var sub = try app.observe(inner, Capture, .{ .outer = outer, .calls = &calls }, Capture.observe);
    defer sub.deinit();
    try outer.update(Outer.change);
    try t.expectEqual(@as(usize, 1), calls);
    try t.expectEqual(@as(usize, 3), scheduler.scheduled);
}

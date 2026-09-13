const std = @import("std");
const t = std.testing;
const ui = @import("root.zig");

const Data = struct {
    value: u32 = 10,
    fn bump(self: *Data, cx: *ui.Context(Data)) !void {
        self.value += 1;
        try cx.notify();
    }
    fn add(self: *Data, amount: u32, cx: *ui.Context(Data)) !void {
        self.value += amount;
        try cx.notify();
    }
};
const Counts = struct { render: usize = 0, layout: usize = 0, prepaint: usize = 0, paint: usize = 0, actions: usize = 0 };
const Increment = struct { amount: u32 = 1 };
const Leaf = struct {
    data: ui.Entity(Data),
    counts: *Counts,
    id: u64,
    focus: ui.FocusHandle,
    phase_data: ?ui.Entity(Data) = null,
    pub fn render(self: *const Leaf, f: *ui.Frame, cx: *ui.Context(Leaf)) !ui.AnyElement {
        self.counts.render += 1;
        const value = try self.data.read();
        const listener = try f.entityInputListener(cx.entity, onInput);
        const action = try f.entityActionListener(cx.entity, Increment, onAction);
        const binding = try f.bindKey("space", .{}, "Leaf", Increment{ .amount = 3 });
        const child = try f.div(.{
            .id = self.id,
            .focus = self.focus,
            .key_context = "Leaf",
            .listeners = &.{ listener, action },
            .bindings = &.{binding},
            .style = .{ .width = .{ .px = @floatFromInt(value.value) }, .height = .{ .px = 40 }, .background = .{ .r = if (f.isFocused(self.focus)) 1 else 0.2, .b = 0.8 } },
        });
        return f.element(Probe{ .counts = self.counts, .child = child, .data = self.phase_data });
    }
    fn onInput(self: *Leaf, event: ui.input.PlatformInput, phase: ui.DispatchPhase, _: *ui.Context(Leaf), ec: *ui.EventContext) !void {
        if (phase == .bubble and event == .mouse_down) {
            try ec.focus(self.focus);
            ec.stopPropagation();
        }
    }
    fn onAction(self: *Leaf, action: *const Increment, phase: ui.DispatchPhase, cx: *ui.Context(Leaf), ec: *ui.EventContext) !void {
        if (phase != .bubble) return;
        self.counts.actions += 1;
        try cx.app.updateWith(self.data, action.amount, Data.add);
        ec.stopPropagation();
    }
};
const Probe = struct {
    pub const RequestLayoutState = void;
    pub const PrepaintState = void;
    counts: *Counts,
    child: ui.AnyElement,
    data: ?ui.Entity(Data),
    pub fn requestLayout(self: *Probe, f: *ui.Frame) !ui.LayoutRequest(void) {
        self.counts.layout += 1;
        if (self.data) |data| _ = try data.read();
        return .{ .id = try self.child.requestLayout(f), .state = {} };
    }
    pub fn prepaint(self: *Probe, f: *ui.Frame, _: ui.geometry.Bounds, _: *void) !void {
        self.counts.prepaint += 1;
        if (self.data) |data| _ = try data.read();
        try self.child.prepaint(f);
    }
    pub fn paint(self: *Probe, f: *ui.Frame, _: ui.geometry.Bounds, _: *void, _: *void) !void {
        self.counts.paint += 1;
        if (self.data) |data| _ = try data.read();
        try self.child.paint(f);
    }
};
const Root = struct {
    a: ui.Entity(Leaf),
    b: ui.Entity(Leaf),
    renders: *usize,
    show_a: bool = true,
    cached: bool = true,
    gap: f32 = 0,
    pub fn render(self: *const Root, f: *ui.Frame, _: *ui.Context(Root)) !ui.AnyElement {
        self.renders.* += 1;
        const options = ui.CachedViewOptions{ .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 60 }, .clip = true } };
        const a = if (!self.show_a) try f.div(.{}) else if (self.cached) try f.cachedView(self.a, options) else try f.view(self.a);
        const b = if (self.cached) try f.cachedView(self.b, options) else try f.view(self.b);
        return f.div(.{ .style = .{ .gap = self.gap }, .children = &.{ a, b } });
    }
    fn hide(self: *Root, cx: *ui.Context(Root)) !void {
        self.show_a = false;
        try cx.notify();
    }
    fn move(self: *Root, cx: *ui.Context(Root)) !void {
        self.gap = 9;
        try cx.notify();
    }
};
fn notify(_: anytype, cx: anytype) !void {
    try cx.notify();
}
fn makeLeaf(app: *ui.App, data: ui.Entity(Data), counts: *Counts, id: u64) !ui.Entity(Leaf) {
    return app.create(Leaf{ .data = data, .counts = counts, .id = id, .focus = app.newFocusHandle() });
}
fn findView(snapshot: *const ui.view_state.Snapshot, entity: u64) *const ui.view_state.View {
    for (snapshot.views.items) |*view| if (view.entity == entity) return view;
    unreachable;
}
fn space() ui.input.PlatformInput {
    return .{ .key_down = .{ .key = "space", .key_code = 49, .modifiers = .{} } };
}

test "per-view reads invalidate readers and ancestors while cached siblings skip all phases" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var a: Counts = .{};
    var b: Counts = .{};
    var renders: usize = 0;
    const da = try app.create(Data{});
    const db = try app.create(Data{});
    const va = try makeLeaf(&app, da, &a, 1);
    const vb = try makeLeaf(&app, db, &b, 2);
    const root = try app.create(Root{ .a = va, .b = vb, .renders = &renders });
    var window = try ui.Window.init(&app, root, .{ .width = 300, .height = 120 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    const snapshot = window.inspect().?;
    try t.expectEqual(@as(usize, 1), findView(snapshot, root.id).dependencies.items.len);
    try t.expectEqual(@as(usize, 2), findView(snapshot, va.id).dependencies.items.len);
    try t.expectEqual(@as(usize, 1), snapshot.readers.get(da.id).?.items.len);
    try da.update(Data.bump);
    _ = try window.drawIfNeeded();
    try t.expectEqual(Counts{ .render = 2, .layout = 2, .prepaint = 2, .paint = 2 }, a);
    try t.expectEqual(Counts{ .render = 1, .layout = 1, .prepaint = 1, .paint = 1 }, b);
    try t.expectEqual(ui.view_state.DirtyReason.ancestor, findView(window.inspect().?, root.id).dirty_reason);
    try t.expectEqual(ui.view_state.DirtyReason.dependency, findView(window.inspect().?, va.id).dirty_reason);
    try t.expect(findView(window.inspect().?, vb.id).reused);
    // Dependencies must survive more than one replay.
    try root.update(notify);
    _ = try window.drawIfNeeded();
    try root.update(notify);
    _ = try window.drawIfNeeded();
    try db.update(Data.bump);
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 2), b.render);
    try t.expectEqual(@as(usize, 2), a.render);
    try root.update(Root.hide);
    _ = try window.drawIfNeeded();
    try t.expect(window.inspect().?.readers.get(da.id) == null);
    try da.update(Data.bump);
    try t.expect(!try window.drawIfNeeded());
}

test "shared data invalidates every reader and independent window; phase reads are tracked" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var a: Counts = .{};
    var b: Counts = .{};
    var renders: usize = 0;
    const data = try app.create(Data{});
    const phases = try app.create(Data{});
    const va = try app.create(Leaf{ .data = data, .phase_data = phases, .counts = &a, .id = 1, .focus = app.newFocusHandle() });
    const vb = try makeLeaf(&app, data, &b, 2);
    const root = try app.create(Root{ .a = va, .b = vb, .renders = &renders });
    var first = try ui.Window.init(&app, root, .{ .width = 300, .height = 120 }, 1);
    defer first.deinit();
    var second = try ui.Window.init(&app, root, first.size, 1);
    defer second.deinit();
    _ = try first.drawIfNeeded();
    _ = try second.drawIfNeeded();
    try t.expectEqual(@as(usize, 2), first.inspect().?.readers.get(data.id).?.items.len);
    try phases.update(Data.bump);
    _ = try first.drawIfNeeded();
    try t.expectEqual(@as(usize, 3), a.render);
    try t.expectEqual(@as(usize, 2), b.render);
    try t.expect(second.needsDraw());
    try data.update(Data.bump);
    _ = try first.drawIfNeeded();
    _ = try second.drawIfNeeded();
    try t.expectEqual(@as(usize, 5), a.render);
    try t.expectEqual(@as(usize, 4), b.render);
}

const Group = struct {
    leaf: ui.Entity(Leaf),
    renders: *usize,
    pub fn render(self: *const Group, f: *ui.Frame, _: *ui.Context(Group)) !ui.AnyElement {
        self.renders.* += 1;
        const child = try f.cachedView(self.leaf, .{ .style = .{ .width = .{ .px = 80 }, .height = .{ .px = 60 }, .clip = true } });
        return f.div(.{ .style = .{ .padding = .{ .left = 3, .top = 4 } }, .children = &.{child} });
    }
};
const Nested = struct {
    group: ui.Entity(Group),
    leaf: ui.Entity(Leaf),
    pub fn render(self: *const Nested, f: *ui.Frame, _: *ui.Context(Nested)) !ui.AnyElement {
        const left = try f.cachedView(self.group, .{ .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } } });
        const right = try f.cachedView(self.leaf, .{ .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } } });
        return f.div(.{ .children = &.{ left, right } });
    }
};
test "nested cache replay remaps descendant caches, focus, hitboxes, listeners and scene ranges" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var a: Counts = .{};
    var b: Counts = .{};
    var group_renders: usize = 0;
    const data = try app.create(Data{});
    const va = try makeLeaf(&app, data, &a, 1);
    const vb = try makeLeaf(&app, data, &b, 2);
    const group = try app.create(Group{ .leaf = va, .renders = &group_renders });
    const root = try app.create(Nested{ .group = group, .leaf = vb });
    var window = try ui.Window.init(&app, root, .{ .width = 300, .height = 120 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    _ = try window.dispatchInput(.{ .mouse_down = .{ .position = .{ .x = 4, .y = 5 }, .button = .left } });
    _ = try window.drawIfNeeded(); // Focus changes the rendering environment.
    const baseline = a;
    for (0..3) |_| {
        try root.update(notify);
        _ = try window.drawIfNeeded();
    }
    try t.expectEqual(baseline, a);
    try t.expectEqual(@as(?u64, 1), window.hitTest(.{ .x = 4, .y = 5 }));
    try group.update(notify);
    _ = try window.drawIfNeeded();
    try t.expectEqual(baseline, a); // Nested cache still usable after parent replay.
    try root.update(notify);
    _ = try window.drawIfNeeded();
    try t.expect((try window.dispatchInput(space())).handled);
    try t.expectEqual(@as(usize, 1), a.actions);
    try t.expectEqual(@as(usize, 0), b.actions);
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(f32, 13), window.renderer.backend.scene.primitives.items[0].quad.bounds.size.width);
    try t.expectEqual(@as(f32, 3), window.renderer.backend.scene.primitives.items[0].quad.bounds.origin.x);
    try t.expectEqual(@as(f32, 100), window.renderer.backend.scene.primitives.items[1].quad.bounds.origin.x);
    try t.expect((try window.dispatchAction(Increment{ .amount = 2 })).handled);
    try t.expectEqual(@as(u32, 15), (try data.read()).value);
    try app.destroy(va);
    // Committed handlers are weak and cannot borrow a destroyed view.
    try t.expect(!(try window.dispatchAction(Increment{})).handled);
    try t.expectError(error.EntityReleased, window.drawIfNeeded());
}

test "geometry, clipping, scale and explicit refresh invalidate cached output" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var a: Counts = .{};
    var b: Counts = .{};
    var renders: usize = 0;
    const data = try app.create(Data{});
    const va = try makeLeaf(&app, data, &a, 1);
    const vb = try makeLeaf(&app, data, &b, 2);
    const root = try app.create(Root{ .a = va, .b = vb, .renders = &renders });
    var window = try ui.Window.init(&app, root, .{ .width = 300, .height = 120 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try root.update(Root.move);
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 1), a.render);
    try t.expectEqual(@as(usize, 2), b.render);
    try t.expectEqual(@as(?u64, 2), window.hitTest(.{ .x = 110, .y = 1 }));
    try window.resize(window.size, 2);
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 2), a.render);
    window.invalidate();
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 3), a.render);
    const expected = try t.allocator.dupe(ui.scene.Primitive, window.renderer.backend.scene.primitives.items);
    defer t.allocator.free(expected);
    try root.update(notify);
    _ = try window.drawIfNeeded();
    try t.expectEqualDeep(expected, window.renderer.backend.scene.primitives.items);
}

const Failing = struct {
    stub: ui.renderer.Stub,
    fail: bool = false,
    pub fn init(a: std.mem.Allocator, size: ui.geometry.Size, scale: f32) !Failing {
        return .{ .stub = try .init(a, size, scale) };
    }
    pub fn deinit(self: *Failing) void {
        self.stub.deinit();
    }
    pub fn resize(self: *Failing, size: ui.geometry.Size, scale: f32) !void {
        try self.stub.resize(size, scale);
    }
    pub fn submit(self: *Failing, scene: *const ui.scene.Scene) !void {
        if (self.fail) return error.NoBackend;
        try self.stub.submit(scene);
    }
};
test "failed presentation retains cache, readers, hitboxes and dispatch until retry" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var a: Counts = .{};
    var b: Counts = .{};
    var renders: usize = 0;
    const data = try app.create(Data{});
    const va = try makeLeaf(&app, data, &a, 1);
    const vb = try makeLeaf(&app, data, &b, 2);
    const root = try app.create(Root{ .a = va, .b = vb, .renders = &renders });
    var window = try ui.WindowWithRenderer(ui.renderer.GenericRenderer(Failing)).init(&app, root, .{ .width = 300, .height = 120 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try window.focus((try va.read()).focus);
    _ = try window.drawIfNeeded();
    const previous = window.inspect().?;
    window.renderer.backend.fail = true;
    try root.update(Root.hide);
    try t.expectError(error.NoBackend, window.drawIfNeeded());
    try t.expect(window.inspect().? == previous);
    try t.expectEqual(@as(?u64, 1), window.hitTest(.{ .x = 1, .y = 1 }));
    try t.expect((try window.dispatchAction(Increment{})).handled);
    window.renderer.backend.fail = false;
    _ = try window.drawIfNeeded();
    try t.expect(window.inspect().? != previous);
    try t.expect(window.focused == null);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var app = ui.App.init(allocator);
    defer app.deinit();
    var a: Counts = .{};
    var b: Counts = .{};
    var renders: usize = 0;
    const data = try app.create(Data{});
    const va = try makeLeaf(&app, data, &a, 1);
    const vb = try makeLeaf(&app, data, &b, 2);
    const root = try app.create(Root{ .a = va, .b = vb, .renders = &renders });
    var window = try ui.Window.init(&app, root, .{ .width = 300, .height = 120 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try window.focus((try va.read()).focus);
    _ = try window.drawIfNeeded();
    try root.update(notify);
    _ = try window.drawIfNeeded();
    _ = try window.dispatchInput(space());
    _ = try window.drawIfNeeded();
    try root.update(Root.hide);
    _ = try window.drawIfNeeded();
}
test "allocation failure releases cached snapshots, copied metadata and owned captures" {
    try t.checkAllAllocationFailures(t.allocator, allocationScenario, .{});
}

const Simple = struct {
    data: ui.Entity(Data),
    renders: *usize,
    pub fn render(self: *const Simple, f: *ui.Frame, _: *ui.Context(Simple)) !ui.AnyElement {
        self.renders.* += 1;
        const value = try self.data.read();
        return f.div(.{ .id = 7, .style = .{ .width = .{ .px = @floatFromInt(value.value) }, .height = .{ .px = 30 }, .background = .{ .g = 0.7, .a = 0.5 } } });
    }
};
test "cached and ordinary boundaries agree on padding, clipping, order and hitboxes" {
    const Compare = struct {
        leaf: ui.Entity(Simple),
        cached: bool,
        clip_width: f32 = 16,
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            const style = ui.Style{ .width = .{ .px = 50 }, .height = .{ .px = 40 }, .padding = .{ .left = 5, .top = 3 }, .background = .{ .r = 0.1 }, .clip = true };
            const child = if (self.cached) try f.cachedView(self.leaf, .{ .style = style }) else try f.div(.{ .style = style, .children = &.{try f.view(self.leaf)} });
            return f.div(.{ .style = .{ .width = .{ .px = self.clip_width }, .height = .{ .px = 25 }, .clip = true }, .children = &.{child} });
        }
        fn changeClip(self: *@This(), cx: *ui.Context(@This())) !void {
            self.clip_width = 12;
            try cx.notify();
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var renders: usize = 0;
    const data = try app.create(Data{ .value = 40 });
    const leaf = try app.create(Simple{ .data = data, .renders = &renders });
    const cached = try app.create(Compare{ .leaf = leaf, .cached = true });
    const normal = try app.create(Compare{ .leaf = leaf, .cached = false });
    var a = try ui.Window.init(&app, cached, .{ .width = 100, .height = 100 }, 1);
    defer a.deinit();
    var b = try ui.Window.init(&app, normal, a.size, 1);
    defer b.deinit();
    _ = try a.drawIfNeeded();
    _ = try b.drawIfNeeded();
    try t.expectEqualDeep(b.renderer.backend.scene.primitives.items, a.renderer.backend.scene.primitives.items);
    try t.expectEqualDeep(b.hitboxes.items[0].bounds, a.hitboxes.items[0].bounds);
    try cached.update(notify);
    _ = try a.drawIfNeeded();
    try t.expectEqualDeep(b.renderer.backend.scene.primitives.items, a.renderer.backend.scene.primitives.items);
    try cached.update(Compare.changeClip);
    _ = try a.drawIfNeeded();
    try normal.update(Compare.changeClip);
    _ = try b.drawIfNeeded();
    try t.expectEqualDeep(b.renderer.backend.scene.primitives.items, a.renderer.backend.scene.primitives.items);
    try t.expect(a.hitTest(.{ .x = 13, .y = 10 }) == null);
}

test "keyed repeated entities have separate occurrences and ambiguous identities fail transactionally" {
    const Repeated = struct {
        leaf: ui.Entity(Simple),
        duplicate: bool = false,
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            const style = ui.Style{ .width = .{ .px = 50 }, .height = .{ .px = 40 } };
            return f.div(.{ .children = &.{
                try f.cachedView(self.leaf, .{ .key = 1, .style = style }),
                try f.cachedView(self.leaf, .{ .key = if (self.duplicate) 1 else 2, .style = style }),
            } });
        }
        fn duplicateKey(self: *@This(), cx: *ui.Context(@This())) !void {
            self.duplicate = true;
            try cx.notify();
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var renders: usize = 0;
    const data = try app.create(Data{});
    const leaf = try app.create(Simple{ .data = data, .renders = &renders });
    const root = try app.create(Repeated{ .leaf = leaf });
    var window = try ui.Window.init(&app, root, .{ .width = 200, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 2), window.inspect().?.view_nodes.get(leaf.id).?.items.len);
    try root.update(notify);
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 2), renders);
    try data.update(Data.bump);
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 4), renders);
    const previous = window.inspect().?;
    try root.update(Repeated.duplicateKey);
    try t.expectError(error.DuplicateViewIdentity, window.drawIfNeeded());
    try t.expect(window.inspect().? == previous);
}

test "recursive view containment is rejected before unbounded rendering" {
    const Recursive = struct {
        pub fn render(_: *const @This(), f: *ui.Frame, cx: *ui.Context(@This())) !ui.AnyElement {
            return f.view(cx.entity);
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const root = try app.create(Recursive{});
    var window = try ui.Window.init(&app, root, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    try t.expectError(error.RecursiveView, window.drawIfNeeded());
    try t.expect(window.inspect() == null);
}

test "display-none view branches drop data readers and dispatch nodes" {
    const Hidden = struct {
        child: ui.Entity(Simple),
        hidden: bool = false,
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            return f.div(.{ .style = .{ .hidden = self.hidden }, .children = &.{try f.view(self.child)} });
        }
        fn hide(self: *@This(), cx: *ui.Context(@This())) !void {
            self.hidden = true;
            try cx.notify();
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var renders: usize = 0;
    const data = try app.create(Data{});
    const child = try app.create(Simple{ .data = data, .renders = &renders });
    const root = try app.create(Hidden{ .child = child });
    var window = try ui.Window.init(&app, root, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try root.update(Hidden.hide);
    _ = try window.drawIfNeeded();
    try t.expect(window.inspect().?.readers.get(data.id) == null);
    try t.expect(window.inspect().?.view_nodes.get(child.id) == null);
    try t.expectEqual(@as(usize, 1), renders);
    try data.update(Data.bump);
    try t.expect(!window.needsDraw());
}

test "explicit invalidation during render survives successful commit" {
    const Refresh = struct {
        window: *?*ui.Window,
        once: *bool,
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            if (!self.once.*) {
                self.once.* = true;
                self.window.*.?.invalidate();
            }
            return f.div(.{});
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var target: ?*ui.Window = null;
    var once = false;
    const root = try app.create(Refresh{ .window = &target, .once = &once });
    var window = try ui.Window.init(&app, root, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    target = &window;
    _ = try window.drawIfNeeded();
    try t.expect(window.needsDraw());
    _ = try window.drawIfNeeded();
    try t.expect(!window.needsDraw());
}

fn nestedAllocationScenario(allocator: std.mem.Allocator) !void {
    var app = ui.App.init(allocator);
    defer app.deinit();
    var a: Counts = .{};
    var b: Counts = .{};
    var renders: usize = 0;
    const data = try app.create(Data{});
    const va = try makeLeaf(&app, data, &a, 1);
    const vb = try makeLeaf(&app, data, &b, 2);
    const group = try app.create(Group{ .leaf = va, .renders = &renders });
    const root = try app.create(Nested{ .group = group, .leaf = vb });
    var window = try ui.Window.init(&app, root, .{ .width = 300, .height = 120 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try root.update(notify);
    _ = try window.drawIfNeeded();
    try group.update(notify);
    _ = try window.drawIfNeeded();
    try root.update(notify);
    _ = try window.drawIfNeeded();
}
test "nested replay allocation failures release descendant snapshots and shared captures" {
    try t.checkAllAllocationFailures(t.allocator, nestedAllocationScenario, .{});
}

test "a custom element may prepaint an unpainted cached child without retaining an invalid paint range" {
    const SkipPaint = struct {
        pub const RequestLayoutState = void;
        pub const PrepaintState = void;
        child: ui.AnyElement,
        pub fn requestLayout(self: *@This(), f: *ui.Frame) !ui.LayoutRequest(void) {
            return .{ .id = try self.child.requestLayout(f), .state = {} };
        }
        pub fn prepaint(self: *@This(), f: *ui.Frame, _: ui.geometry.Bounds, _: *void) !void {
            try self.child.prepaint(f);
        }
        pub fn paint(_: *@This(), _: *ui.Frame, _: ui.geometry.Bounds, _: *void, _: *void) !void {}
    };
    const Parent = struct {
        leaf: ui.Entity(Simple),
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            return f.element(SkipPaint{ .child = try f.cachedView(self.leaf, .{ .style = .{ .width = .{ .px = 50 }, .height = .{ .px = 40 } } }) });
        }
    };
    const Outer = struct {
        child: ui.Entity(Parent),
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            return f.div(.{ .style = .{ .background = .{ .r = 0.5 } }, .children = &.{
                try f.cachedView(self.child, .{ .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 80 }, .background = .{ .g = 0.5 } } }),
            } });
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    var renders: usize = 0;
    const data = try app.create(Data{});
    const leaf = try app.create(Simple{ .data = data, .renders = &renders });
    const parent = try app.create(Parent{ .leaf = leaf });
    const root = try app.create(Outer{ .child = parent });
    var window = try ui.Window.init(&app, root, .{ .width = 200, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try t.expect(findView(window.inspect().?, leaf.id).cache == null);
    for (0..3) |_| {
        try root.update(notify);
        _ = try window.drawIfNeeded();
    }
    try t.expectEqual(@as(usize, 1), renders);
    try t.expectEqual(@as(usize, 2), window.renderer.backend.scene.primitives.items.len);
    try parent.update(notify);
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 2), renders);
}

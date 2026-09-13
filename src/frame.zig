const std = @import("std");
const g = @import("geometry.zig");
const elements = @import("element.zig");
const reactive = @import("app.zig");
const views = @import("view_state.zig");
const dispatch = @import("dispatch.zig");
pub const Phase = enum { render, request_layout, compute_layout, prepaint, paint, complete };
pub const Hitbox = views.Hitbox;

pub const Frame = struct {
    arena: std.heap.ArenaAllocator,
    app: *reactive.App,
    layout: @import("layout.zig").Layout,
    scene: @import("scene.zig").Scene = .{},
    hitboxes: std.ArrayList(Hitbox) = .empty,
    phase: Phase = .render,
    size: g.Size,
    clip: g.Bounds,
    scale: f32,
    snapshot: *views.Snapshot,
    owns_snapshot: bool = true,
    previous: ?*const views.Snapshot = null,
    dirty_views: []const views.DirtyReason = &.{},
    active_view: ?usize = null,
    active_node: ?dispatch.NodeId = null,
    focused: ?u64 = null,

    pub fn init(app: *reactive.App, size: g.Size, scale: f32) !Frame {
        const snapshot = try views.Snapshot.create(app.allocator);
        errdefer snapshot.destroy();
        return .{ .arena = std.heap.ArenaAllocator.init(app.allocator), .app = app, .layout = try .init(app.allocator, scale), .size = size, .clip = .{ .size = size }, .scale = scale, .snapshot = snapshot };
    }
    pub fn deinit(self: *Frame) void {
        self.layout.deinit();
        self.arena.deinit();
        if (self.owns_snapshot) self.snapshot.destroy();
    }
    pub fn allocator(self: *Frame) std.mem.Allocator {
        return self.arena.allocator();
    }
    pub fn element(self: *Frame, value: anytype) !elements.AnyElement {
        return elements.AnyElement.init(self, value);
    }
    pub fn div(self: *Frame, value: elements.Div) !elements.AnyElement {
        var owned = value;
        owned.children = try self.allocator().dupe(elements.AnyElement, value.children);
        owned.listeners = try self.allocator().dupe(dispatch.Listener, value.listeners);
        owned.bindings = try self.allocator().dupe(dispatch.Binding, value.bindings);
        owned.key_context = if (value.key_context) |name| try self.allocator().dupe(u8, name) else null;
        return self.element(owned);
    }
    pub fn view(self: *Frame, entity: anytype) !elements.AnyElement {
        if (self.phase != .render) return error.InvalidPhase;
        return @import("view.zig").create(self, entity, 0, null);
    }
    pub fn keyedView(self: *Frame, entity: anytype, key: u64) !elements.AnyElement {
        if (self.phase != .render) return error.InvalidPhase;
        return @import("view.zig").create(self, entity, key, null);
    }
    pub fn cachedView(self: *Frame, entity: anytype, options: @import("view.zig").CachedViewOptions) !elements.AnyElement {
        if (self.phase != .render) return error.InvalidPhase;
        return @import("view.zig").create(self, entity, options.key, options.style);
    }
    pub fn hitbox(self: *Frame, id: u64, bounds: g.Bounds) !void {
        if (self.phase != .prepaint) return error.InvalidPhase;
        try self.hitboxes.append(self.allocator(), .{ .id = id, .bounds = bounds.intersect(self.clip), .node = self.active_node });
    }
    pub fn draw(self: *Frame, root: elements.AnyElement) !void {
        if (self.phase != .render) return error.InvalidPhase;
        const old_tracker = self.app.view_tracking;
        self.app.view_tracking = .{ .context = self, .record = recordDependency };
        defer self.app.view_tracking = old_tracker;
        self.phase = .request_layout;
        const id = try root.requestLayout(self);
        self.phase = .compute_layout;
        self.layout.compute(id, self.size);
        self.phase = .prepaint;
        try root.prepaint(self);
        self.phase = .paint;
        try root.paint(self);
        self.snapshot.scene = try self.snapshot.memory().dupe(@import("scene.zig").Primitive, self.scene.primitives.items);
        self.snapshot.hitboxes = try self.snapshot.memory().dupe(Hitbox, self.hitboxes.items);
        try self.snapshot.indexReaders();
        self.phase = .complete;
    }

    fn recordDependency(ptr: *anyopaque, dep: reactive.Dependency) !void {
        const self: *Frame = @ptrCast(@alignCast(ptr));
        if (self.active_view) |view_id| try self.snapshot.track(view_id, dep);
    }
    pub fn addView(self: *Frame, entity: reactive.EntityId, key: u64) !usize {
        var ancestor = self.active_view;
        while (ancestor) |id| {
            if (self.snapshot.views.items[id].entity == entity) return error.RecursiveView;
            ancestor = self.snapshot.views.items[id].parent;
        }
        for (self.snapshot.views.items) |v| if (v.parent == self.active_view and v.entity == entity and v.key == key) return error.DuplicateViewIdentity;
        var old: ?usize = null;
        if (self.previous) |previous| {
            const old_parent = if (self.active_view) |id| self.snapshot.views.items[id].previous else null;
            if (self.active_view == null or old_parent != null) {
                for (previous.views.items, 0..) |v, i| if (v.entity == entity and v.key == key and v.parent == old_parent) {
                    old = i;
                    break;
                };
            }
        }
        const id = self.snapshot.views.items.len;
        try self.snapshot.views.append(self.snapshot.memory(), .{
            .entity = entity,
            .key = key,
            .parent = self.active_view,
            .previous = old,
            .dirty_reason = if (old) |i| self.dirty_views[i] else .new_view,
        });
        return id;
    }
    pub fn pushNode(self: *Frame) !dispatch.NodeId {
        const id = self.snapshot.tree.nodes.items.len;
        try self.snapshot.tree.nodes.append(self.snapshot.memory(), .{ .parent = self.active_node });
        return id;
    }
    pub fn configureNode(self: *Frame, focus: ?dispatch.FocusHandle, context: ?[]const u8, listeners: []const dispatch.Listener, bindings: []const dispatch.Binding, text_input: ?dispatch.TextInput) !void {
        const id = self.active_node orelse return error.NoDispatchNode;
        if (focus) |handle| {
            if (handle.app != self.app) return error.WrongApp;
            try self.snapshot.tree.registerFocus(self.snapshot.memory(), handle.id, id);
            self.snapshot.tree.nodes.items[id].focus = handle.id;
        }
        if (context) |name| self.snapshot.tree.nodes.items[id].context = try self.snapshot.memory().dupe(u8, name);
        try self.snapshot.tree.nodes.items[id].listeners.appendSlice(self.snapshot.memory(), listeners);
        try self.snapshot.tree.nodes.items[id].bindings.appendSlice(self.snapshot.memory(), bindings);
        self.snapshot.tree.nodes.items[id].text_input = text_input;
    }
    pub fn isFocused(self: *const Frame, handle: dispatch.FocusHandle) bool {
        return handle.app == self.app and self.focused == handle.id;
    }
    /// Adapter methods take *Capture and implement the portable text queries.
    /// Capture ownership is the same as for input/action listeners.
    pub fn textInputHandler(self: *Frame, capture: anytype, comptime Adapter: type) !dispatch.TextInput {
        const C = @TypeOf(capture);
        const I = @import("input.zig");
        const Wrapper = struct {
            fn cast(ptr: *anyopaque) *C {
                return @ptrCast(@alignCast(ptr));
            }
            fn selected(ptr: *anyopaque) ?I.TextRange {
                return Adapter.selectedRange(cast(ptr));
            }
            fn marked(ptr: *anyopaque) ?I.TextRange {
                return Adapter.markedRange(cast(ptr));
            }
            fn text(ptr: *anyopaque, range: I.TextRange) ?[]const u8 {
                return Adapter.textForRange(cast(ptr), range);
            }
            fn bounds(ptr: *anyopaque, range: I.TextRange) ?g.Bounds {
                return Adapter.boundsForRange(cast(ptr), range);
            }
            fn index(ptr: *anyopaque, point: g.Point) ?usize {
                return Adapter.characterIndex(cast(ptr), point);
            }
        };
        const payload = try self.ownValue(capture);
        return .{ .capture = payload, .handler = .{ .context = payload.ptr, .selected_range = Wrapper.selected, .marked_range = Wrapper.marked, .text_for_range = Wrapper.text, .bounds_for_range = Wrapper.bounds, .character_index = Wrapper.index } };
    }
    pub fn inputListener(self: *Frame, capture: anytype, comptime callback: anytype) !dispatch.Listener {
        const C = @TypeOf(capture);
        const Adapter = struct {
            fn invoke(ptr: *anyopaque, event: ?@import("input.zig").PlatformInput, _: ?*const anyopaque, phase: dispatch.Phase, cx: *dispatch.EventContext) !void {
                try callback(@as(*C, @ptrCast(@alignCast(ptr))), event.?, phase, cx);
            }
        };
        const payload = try self.ownValue(capture);
        return .{ .capture = payload, .invoke = Adapter.invoke };
    }
    pub fn actionListener(self: *Frame, comptime Action: type, capture: anytype, comptime callback: anytype) !dispatch.Listener {
        const C = @TypeOf(capture);
        const Adapter = struct {
            fn invoke(ptr: *anyopaque, _: ?@import("input.zig").PlatformInput, action: ?*const anyopaque, phase: dispatch.Phase, cx: *dispatch.EventContext) !void {
                try callback(@as(*C, @ptrCast(@alignCast(ptr))), @as(*const Action, @ptrCast(@alignCast(action.?))), phase, cx);
            }
        };
        const payload = try self.ownValue(capture);
        return .{ .capture = payload, .action_type = @typeName(Action), .invoke = Adapter.invoke };
    }
    pub fn entityInputListener(self: *Frame, entity: anytype, comptime callback: anytype) !dispatch.Listener {
        const Weak = @TypeOf(entity.downgrade());
        const Adapter = struct {
            fn call(weak: *Weak, event: @import("input.zig").PlatformInput, phase: dispatch.Phase, cx: *dispatch.EventContext) !void {
                const handle = weak.upgrade() orelse return;
                try cx.app.updateWith(handle, .{ event, phase, cx }, update);
            }
            fn update(value: *@TypeOf(entity).Value, args: anytype, cx: *reactive.Context(@TypeOf(entity).Value)) !void {
                try callback(value, args[0], args[1], cx, args[2]);
            }
        };
        return self.inputListener(entity.downgrade(), Adapter.call);
    }
    pub fn entityActionListener(self: *Frame, entity: anytype, comptime Action: type, comptime callback: anytype) !dispatch.Listener {
        const Weak = @TypeOf(entity.downgrade());
        const Adapter = struct {
            fn call(weak: *Weak, action: *const Action, phase: dispatch.Phase, cx: *dispatch.EventContext) !void {
                const handle = weak.upgrade() orelse return;
                try cx.app.updateWith(handle, .{ action, phase, cx }, update);
            }
            fn update(value: *@TypeOf(entity).Value, args: anytype, cx: *reactive.Context(@TypeOf(entity).Value)) !void {
                try callback(value, args[0], args[1], cx, args[2]);
            }
        };
        return self.actionListener(Action, entity.downgrade(), Adapter.call);
    }
    pub fn bindKey(self: *Frame, key: []const u8, modifiers: @import("input.zig").Modifiers, context: ?[]const u8, action: anytype) !dispatch.Binding {
        const owned_key = try self.snapshot.memory().dupe(u8, key);
        const owned_context = if (context) |name| try self.snapshot.memory().dupe(u8, name) else null;
        const payload = try self.ownValue(action);
        return .{ .key = owned_key, .modifiers = modifiers, .context = owned_context, .action = payload };
    }
    fn ownValue(self: *Frame, value: anytype) !*dispatch.Payload {
        // Reserve first: failed registration leaves value ownership with caller.
        try self.snapshot.owners.ensureUnusedCapacity(self.snapshot.memory(), 1);
        const payload = try dispatch.Payload.create(self.app.allocator, value);
        self.snapshot.owners.appendAssumeCapacity(payload);
        return payload;
    }

    /// Graft cached prepaint output; all old IDs are translated to this frame.
    pub fn reusePrepaint(self: *Frame, view_id: usize, cache: views.Cache) !void {
        const old = self.previous.?;
        const previous_view = self.snapshot.views.items[view_id].previous.?;
        const node_start = self.snapshot.tree.nodes.items.len;
        const hit_start = self.hitboxes.items.len;
        const view_map = try self.allocator().alloc(?usize, old.views.items.len);
        @memset(view_map, null);
        view_map[previous_view] = view_id;
        const node_map = try self.allocator().alloc(?usize, old.tree.nodes.items.len);
        @memset(node_map, null);
        node_map[old.views.items[previous_view].dispatch_node.?] = self.active_node;
        for (old.views.items, 0..) |v, i| {
            if (i == previous_view or !old.descendant(i, previous_view)) continue;
            const id = self.snapshot.views.items.len;
            view_map[i] = id;
            var copy = v;
            copy.previous = i;
            copy.parent = view_map[v.parent.?].?;
            copy.dependencies = .empty;
            copy.dirty_reason = .clean;
            copy.reused = true;
            try self.snapshot.views.append(self.snapshot.memory(), copy);
        }
        const saved_view = self.active_view;
        defer self.active_view = saved_view;
        for (view_map, 0..) |mapped, i| if (mapped) |id| {
            self.active_view = id;
            for (old.views.items[i].dependencies.items) |dep| try self.app.track(dep.id);
        };
        for (old.tree.nodes.items[cache.nodes.start..cache.nodes.end], cache.nodes.start..) |node, old_id| {
            const id = self.snapshot.tree.nodes.items.len;
            node_map[old_id] = id;
            var copy = node;
            copy.parent = if (node.parent) |parent| node_map[parent].? else null;
            copy.view = if (node.view) |owner| view_map[owner].? else null;
            copy.context = if (node.context) |name| try self.snapshot.memory().dupe(u8, name) else null;
            copy.listeners = .empty;
            copy.bindings = .empty;
            if (copy.focus) |focus| try self.snapshot.tree.registerFocus(self.snapshot.memory(), focus, id);
            if (copy.text_input) |text_input| try self.snapshot.own(text_input.capture.retain());
            for (node.listeners.items) |listener| {
                try self.snapshot.own(listener.capture.retain());
                try copy.listeners.append(self.snapshot.memory(), listener);
            }
            for (node.bindings.items) |binding| {
                try self.snapshot.own(binding.action.retain());
                var b = binding;
                b.key = try self.snapshot.memory().dupe(u8, b.key);
                b.context = if (b.context) |name| try self.snapshot.memory().dupe(u8, name) else null;
                try copy.bindings.append(self.snapshot.memory(), b);
            }
            try self.snapshot.tree.nodes.append(self.snapshot.memory(), copy);
        }
        for (old.hitboxes[cache.hitboxes.start..cache.hitboxes.end]) |hit| {
            var copy = hit;
            copy.node = if (hit.node) |id| node_map[id].? else null;
            try self.hitboxes.append(self.allocator(), copy);
        }
        for (view_map, 0..) |mapped, i| if (mapped) |id| {
            if (i == previous_view) continue;
            const v = &self.snapshot.views.items[id];
            v.dispatch_node = if (old.views.items[i].dispatch_node) |node| node_map[node] else null;
            if (v.cache) |*nested| {
                nested.nodes = rebase(nested.nodes, cache.nodes.start, node_start);
                nested.hitboxes = rebase(nested.hitboxes, cache.hitboxes.start, hit_start);
            }
        };
        self.snapshot.views.items[view_id].reused = true;
        self.snapshot.cache_hits += 1;
    }
    pub fn reusePaint(self: *Frame, view_id: usize, cache: views.Cache) !void {
        const start = self.scene.primitives.items.len;
        try self.scene.primitives.appendSlice(self.allocator(), self.previous.?.scene[cache.scene.start..cache.scene.end]);
        for (self.snapshot.views.items, 0..) |*v, i| {
            if (i == view_id or !self.snapshot.descendant(i, view_id)) continue;
            if (v.cache) |*nested| nested.scene = rebase(nested.scene, cache.scene.start, start);
        }
    }
    fn rebase(range: views.Range, old: usize, new: usize) views.Range {
        return .{ .start = range.start - old + new, .end = range.end - old + new };
    }
};

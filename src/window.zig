const std = @import("std");
const reactive = @import("app.zig");
const g = @import("geometry.zig");
const frame = @import("frame.zig");
const AnyElement = @import("element.zig").AnyElement;
const views = @import("view_state.zig");
const dispatch = @import("dispatch.zig");
const input = @import("input.zig");

pub const Window = WindowWithRenderer(@import("renderer.zig").Renderer);

/// The platform host calls drawIfNeeded after updates or an OS frame request.
pub fn WindowWithRenderer(comptime Renderer: type) type {
    return struct {
        const Self = @This();
        app: *reactive.App,
        root_id: reactive.EntityId,
        render: *const fn (*frame.Frame, reactive.EntityId) anyerror!AnyElement,
        renderer: Renderer,
        size: g.Size,
        scale: f32,
        dirty: bool = true,
        drawing: bool = false,
        dispatching: bool = false,
        refresh: bool = true,
        invalidation_revision: u64 = 0,
        focused: ?u64 = null,
        snapshot: ?*views.Snapshot = null,
        text_revision: u64 = 0,
        text_generation: u64 = 0,
        dependencies: std.ArrayList(reactive.Dependency) = .empty,
        hitboxes: std.ArrayList(frame.Hitbox) = .empty,

        pub fn init(app: *reactive.App, root: anytype, size: g.Size, scale: f32) !Self {
            var renderer = try Renderer.init(app.allocator, size, scale);
            errdefer renderer.deinit();
            return initWithRenderer(app, root, size, scale, renderer);
        }
        /// Transfers renderer ownership on success only.
        pub fn initWithRenderer(app: *reactive.App, root: anytype, size: g.Size, scale: f32, renderer: Renderer) !Self {
            _ = try app.read(root);
            try validateSize(size, scale);
            const Adapter = struct {
                fn render(f: *frame.Frame, id: reactive.EntityId) !AnyElement {
                    return f.view(@TypeOf(root){ .app = f.app, .id = id });
                }
            };
            return .{ .app = app, .root_id = root.id, .render = Adapter.render, .renderer = renderer, .size = size, .scale = scale };
        }
        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.drawing and !self.dispatching);
            if (self.snapshot) |snapshot| snapshot.destroy();
            self.hitboxes.deinit(self.app.allocator);
            self.dependencies.deinit(self.app.allocator);
            self.renderer.deinit();
        }
        pub fn invalidate(self: *Self) void {
            self.dirty = true;
            self.refresh = true;
            self.invalidation_revision += 1;
            if (self.app.wakeup) |wake| wake.schedule(wake.context);
        }
        pub fn resize(self: *Self, size: g.Size, scale: f32) !void {
            if (self.drawing) return error.FrameDuringUpdate;
            try validateSize(size, scale);
            try self.renderer.resize(size, scale);
            self.size = size;
            self.scale = scale;
            self.invalidate();
        }
        pub fn needsDraw(self: *const Self) bool {
            if (self.dirty) return true;
            if (self.textChanged()) return true;
            for (self.dependencies.items) |dep| {
                if (self.app.revision(dep.id) != dep.revision) return true;
            }
            return false;
        }
        fn textChanged(self: *const Self) bool {
            return self.text_revision != self.app.text_revision or self.text_generation != (if (self.app.text_system) |system| system.generation else 0);
        }
        pub fn drawIfNeeded(self: *Self) !bool {
            if (self.drawing or self.dispatching or self.app.tracking != null or self.app.view_tracking != null or self.app.depth != 0 or self.app.flushing) return error.FrameDuringUpdate;
            try self.app.flush();
            if (!self.needsDraw()) return false;
            const invalidation_revision = self.invalidation_revision;
            self.drawing = true;
            defer self.drawing = false;
            // On failure keep the previous scene, dependencies and hitboxes.
            self.dirty = true;
            var next = try frame.Frame.init(self.app, self.size, self.scale);
            defer next.deinit();
            next.previous = self.snapshot;
            next.focused = self.focused;
            if (self.snapshot) |snapshot| next.dirty_views = try snapshot.dirtyViews(next.allocator(), self.app, self.refresh or self.textChanged());
            const text_revision = self.app.text_revision;
            const text_generation = if (self.app.text_system) |system| system.generation else 0;
            var deps: std.ArrayList(reactive.Dependency) = .empty;
            defer deps.deinit(self.app.allocator);
            self.app.tracking = &deps;
            defer self.app.tracking = null;
            const root = try self.render(&next, self.root_id);
            try next.draw(root);
            try self.hitboxes.ensureTotalCapacity(self.app.allocator, next.hitboxes.items.len);
            try self.renderer.submit(&next.scene);
            std.mem.swap(std.ArrayList(reactive.Dependency), &deps, &self.dependencies);
            self.hitboxes.clearRetainingCapacity();
            self.hitboxes.appendSliceAssumeCapacity(next.hitboxes.items);
            const previous = self.snapshot;
            self.snapshot = next.snapshot;
            next.owns_snapshot = false;
            if (previous) |snapshot| snapshot.destroy();
            self.dirty = self.invalidation_revision != invalidation_revision;
            self.refresh = self.dirty;
            self.text_revision = text_revision;
            self.text_generation = text_generation;
            const old_focus = self.focused;
            self.reconcileFocus(old_focus);
            return true;
        }
        pub fn inspect(self: *const Self) ?*const views.Snapshot {
            return self.snapshot;
        }
        pub fn focusedTextInput(self: *const Self) ?input.TextInputHandler {
            const snapshot = self.snapshot orelse return null;
            var current = snapshot.tree.focusNode(self.focused orelse return null);
            while (current) |id| {
                const node = snapshot.tree.nodes.items[id];
                if (node.text_input) |text_input| return text_input.handler;
                current = node.parent;
            }
            return null;
        }
        pub fn focus(self: *Self, handle: dispatch.FocusHandle) !void {
            if (handle.app != self.app) return error.WrongApp;
            const snapshot = self.snapshot orelse return error.FocusUnavailable;
            if (snapshot.tree.focusNode(handle.id) == null) return error.FocusUnavailable;
            if (self.focused != handle.id) {
                self.focused = handle.id;
                self.invalidate();
            }
        }
        pub fn blur(self: *Self) void {
            if (self.focused != null) {
                self.focused = null;
                self.invalidate();
            }
        }
        fn reconcileFocus(self: *Self, old: ?u64) void {
            if (self.focused) |id| {
                if (self.snapshot == null or self.snapshot.?.tree.focusNode(id) == null) self.focused = null;
            }
            if (old != self.focused) self.invalidate();
        }
        fn inputTarget(self: *const Self, event: ?input.PlatformInput) ?dispatch.NodeId {
            const snapshot = self.snapshot orelse return null;
            if (snapshot.tree.nodes.items.len == 0) return null;
            if (event) |e| if (e.position()) |point| {
                var i = self.hitboxes.items.len;
                while (i > 0) {
                    i -= 1;
                    if (self.hitboxes.items[i].bounds.contains(point)) return self.hitboxes.items[i].node;
                }
                return self.rootTarget();
            };
            if (self.focused) |id| if (snapshot.tree.focusNode(id)) |node| return node;
            return self.rootTarget();
        }
        fn rootTarget(self: *const Self) dispatch.NodeId {
            const nodes = self.snapshot.?.tree.nodes.items;
            var id: usize = 0;
            while (nodes[id].view != null and id + 1 < nodes.len and nodes[id + 1].parent == id) id += 1;
            return id;
        }
        pub fn dispatchInput(self: *Self, event: input.PlatformInput) !input.DispatchEventResult {
            if (self.dispatching or self.drawing or self.app.depth != 0 or self.app.flushing) return error.InputDuringUpdate;
            const target = self.inputTarget(event) orelse return .{};
            self.dispatching = true;
            defer self.dispatching = false;
            const old_focus = self.focused;
            defer self.reconcileFocus(old_focus);
            var cx = dispatch.EventContext{ .app = self.app, .focused = &self.focused, .tree = &self.snapshot.?.tree };
            try self.snapshot.?.tree.dispatch(target, event, &cx);
            try self.app.flush();
            return .{ .handled = cx.handled };
        }
        pub fn dispatchAction(self: *Self, action: anytype) !input.DispatchEventResult {
            if (self.dispatching or self.drawing or self.app.depth != 0 or self.app.flushing) return error.InputDuringUpdate;
            const target = self.inputTarget(null) orelse return .{};
            const payload = try dispatch.Payload.create(self.app.allocator, action);
            defer payload.release();
            self.dispatching = true;
            defer self.dispatching = false;
            const old_focus = self.focused;
            defer self.reconcileFocus(old_focus);
            var cx = dispatch.EventContext{ .app = self.app, .focused = &self.focused, .tree = &self.snapshot.?.tree };
            try self.snapshot.?.tree.dispatchAction(target, payload, &cx);
            try self.app.flush();
            return .{ .handled = cx.handled };
        }
        /// Reverse paint order: the last painted hitbox wins.
        pub fn hitTest(self: *const Self, point: g.Point) ?u64 {
            var i = self.hitboxes.items.len;
            while (i > 0) {
                i -= 1;
                if (self.hitboxes.items[i].bounds.contains(point)) return self.hitboxes.items[i].id;
            }
            return null;
        }
    };
}

fn validateSize(size: g.Size, scale: f32) !void {
    if (!std.math.isFinite(size.width) or !std.math.isFinite(size.height) or size.width < 0 or size.height < 0) return error.InvalidSize;
    if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidScale;
}

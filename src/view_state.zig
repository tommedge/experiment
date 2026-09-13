const std = @import("std");
const app = @import("app.zig");
const g = @import("geometry.zig");
const dispatch = @import("dispatch.zig");
const layout = @import("layout.zig");
const Primitive = @import("scene.zig").Primitive;

/// Clipped pointer target: id is application-defined, while node links the hit
/// to the containing snapshot's dispatch tree for capture/bubble routing.
pub const Hitbox = struct { id: u64, bounds: g.Bounds, node: ?dispatch.NodeId = null };
/// Half-open index interval [start, end) into one snapshot output array.
/// Replay rebases these intervals rather than retaining old array pointers.
pub const Range = struct { start: usize, end: usize };
/// Geometry and rendering inputs that must match before cached output can be
/// reused. Entity dependencies and explicit refresh are checked separately.
pub const CacheKey = struct {
    bounds: g.Bounds,
    clip: g.Bounds,
    viewport: g.Size,
    scale: f32,
    style: layout.Style,
};
/// A view subtree's reusable output ranges and their validity key. Node ranges
/// exclude the boundary node, which is recreated on replay. painted distinguishes
/// a complete cache from a child that was prepainted but never painted.
pub const Cache = struct { key: CacheKey, nodes: Range, hitboxes: Range, scene: Range, painted: bool = false };
pub const DirtyReason = enum { clean, new_view, dependency, ancestor, refresh, geometry };
/// Metadata for one occurrence of an entity-backed view, not the entity itself.
/// Parent path, entity and key identify the occurrence; dependencies record its
/// direct reads. previous links to its match in the preceding frame while building
/// a candidate, and cache/reused describe the output selected for this frame.
pub const View = struct {
    entity: app.EntityId,
    key: u64,
    parent: ?usize,
    previous: ?usize = null,
    dependencies: std.ArrayList(app.Dependency) = .empty,
    dispatch_node: ?usize = null,
    cache: ?Cache = null,
    dirty_reason: DirtyReason = .new_view,
    reused: bool = false,
};

/// A committed frame owns all persistent metadata. Cache ranges point into this
/// snapshot, never into temporary elements or Yoga nodes. Replay copies ranges
/// into a candidate snapshot, so old frames do not form retention chains.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    views: std.ArrayList(View) = .empty,
    tree: dispatch.Tree = .{},
    owners: std.ArrayList(*dispatch.Payload) = .empty,
    scene: []const Primitive = &.{},
    hitboxes: []const Hitbox = &.{},
    readers: std.AutoHashMapUnmanaged(app.EntityId, std.ArrayList(usize)) = .empty,
    view_nodes: std.AutoHashMapUnmanaged(app.EntityId, std.ArrayList(dispatch.NodeId)) = .empty,
    cache_hits: usize = 0,
    cache_misses: usize = 0,

    pub fn create(a: std.mem.Allocator) !*Snapshot {
        const self = try a.create(Snapshot);
        self.* = .{ .allocator = a, .arena = .init(a) };
        return self;
    }
    pub fn memory(self: *Snapshot) std.mem.Allocator {
        return self.arena.allocator();
    }
    pub fn destroy(self: *Snapshot) void {
        for (self.owners.items) |owner| owner.release();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    pub fn own(self: *Snapshot, payload: *dispatch.Payload) !void {
        errdefer payload.release();
        try self.owners.append(self.memory(), payload);
    }
    pub fn track(self: *Snapshot, view: usize, dependency: app.Dependency) !void {
        for (self.views.items[view].dependencies.items) |existing| if (existing.id == dependency.id) return;
        try self.views.items[view].dependencies.append(self.memory(), dependency);
    }
    pub fn indexReaders(self: *Snapshot) !void {
        // Custom elements may prepaint a child without ever painting it. Such a
        // child has no valid paint range and cannot be an independent cache hit.
        for (self.views.items) |*view| if (view.cache) |cache| {
            if (!cache.painted) view.cache = null;
        };
        for (self.views.items) |view| if (view.dispatch_node) |node| {
            const entry = try self.view_nodes.getOrPut(self.memory(), view.entity);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.memory(), node);
        };
        for (self.views.items, 0..) |view, i| for (view.dependencies.items) |dep| {
            const entry = try self.readers.getOrPut(self.memory(), dep.id);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.memory(), i);
        };
    }
    pub fn descendant(self: *const Snapshot, child: usize, ancestor: usize) bool {
        var current: ?usize = child;
        while (current) |id| {
            if (id == ancestor) return true;
            current = self.views.items[id].parent;
        }
        return false;
    }
    pub fn dirtyViews(self: *const Snapshot, a: std.mem.Allocator, application: *app.App, refresh: bool) ![]DirtyReason {
        const result = try a.alloc(DirtyReason, self.views.items.len);
        @memset(result, if (refresh) .refresh else .clean);
        if (refresh) return result;
        var readers = self.readers.iterator();
        while (readers.next()) |entry| {
            for (entry.value_ptr.items) |reader| {
                for (self.views.items[reader].dependencies.items) |dep| {
                    if (dep.id == entry.key_ptr.* and application.revision(dep.id) != dep.revision) {
                        result[reader] = .dependency;
                        var parent = self.views.items[reader].parent;
                        while (parent) |id| {
                            if (result[id] == .clean) result[id] = .ancestor;
                            parent = self.views.items[id].parent;
                        }
                        break;
                    }
                }
            }
        }
        return result;
    }
};

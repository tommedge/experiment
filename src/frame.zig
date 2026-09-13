const std = @import("std");
const g = @import("geometry.zig");
const elements = @import("element.zig");
const reactive = @import("app.zig");
pub const Phase = enum { render, request_layout, compute_layout, prepaint, paint, complete };
pub const Hitbox = struct { id: u64, bounds: g.Bounds };

pub const Frame = struct {
    arena: std.heap.ArenaAllocator,
    app: *reactive.App,
    layout: @import("layout.zig").Layout,
    scene: @import("scene.zig").Scene = .{},
    hitboxes: std.ArrayList(Hitbox) = .empty,
    phase: Phase = .render,
    size: g.Size,
    clip: g.Bounds,

    pub fn init(app: *reactive.App, size: g.Size, scale: f32) !Frame {
        return .{ .arena = std.heap.ArenaAllocator.init(app.allocator), .app = app, .layout = try .init(app.allocator, scale), .size = size, .clip = .{ .size = size } };
    }
    pub fn deinit(self: *Frame) void {
        self.layout.deinit();
        self.arena.deinit();
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
        return self.element(owned);
    }
    pub fn view(self: *Frame, entity: anytype) !elements.AnyElement {
        if (self.phase != .render) return error.InvalidPhase;
        const state = try self.app.read(entity);
        var cx = reactive.Context(@TypeOf(entity).Value){ .app = self.app, .entity = entity };
        return state.render(self, &cx);
    }
    pub fn hitbox(self: *Frame, id: u64, bounds: g.Bounds) !void {
        if (self.phase != .prepaint) return error.InvalidPhase;
        try self.hitboxes.append(self.allocator(), .{ .id = id, .bounds = bounds.intersect(self.clip) });
    }
    pub fn draw(self: *Frame, root: elements.AnyElement) !void {
        if (self.phase != .render) return error.InvalidPhase;
        self.phase = .request_layout;
        const id = try root.requestLayout(self);
        self.phase = .compute_layout;
        self.layout.compute(id, self.size);
        self.phase = .prepaint;
        try root.prepaint(self);
        self.phase = .paint;
        try root.paint(self);
        self.phase = .complete;
    }
};

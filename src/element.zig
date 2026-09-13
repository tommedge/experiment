const std = @import("std");
const layout = @import("layout.zig");
const g = @import("geometry.zig");
const Frame = @import("frame.zig").Frame;

pub fn LayoutRequest(comptime State: type) type {
    return struct { id: layout.LayoutId, state: State };
}
pub const Phase = enum { start, layout_requested, prepainted, painted };

/// Frame-arena-owned element. Custom element values and phase states should
/// allocate from Frame.allocator(); resources needing deinit belong in entities.
pub const AnyElement = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    const VTable = struct {
        request: *const fn (*anyopaque, *Frame) anyerror!layout.LayoutId,
        prepaint: *const fn (*anyopaque, *Frame) anyerror!void,
        paint: *const fn (*anyopaque, *Frame) anyerror!void,
    };

    pub fn init(frame: *Frame, value: anytype) !AnyElement {
        const E = @TypeOf(value);
        const Drawable = struct {
            value: E,
            phase: Phase = .start,
            id: layout.LayoutId = undefined,
            request_state: E.RequestLayoutState = undefined,
            prepaint_state: E.PrepaintState = undefined,
            fn request(raw: *anyopaque, f: *Frame) !layout.LayoutId {
                const self: *@This() = @ptrCast(@alignCast(raw));
                if (self.phase != .start or f.phase != .request_layout) return error.InvalidPhase;
                const result = try self.value.requestLayout(f);
                self.id = result.id;
                self.request_state = result.state;
                self.phase = .layout_requested;
                return self.id;
            }
            fn prepaint(raw: *anyopaque, f: *Frame) !void {
                const self: *@This() = @ptrCast(@alignCast(raw));
                if (self.phase != .layout_requested or f.phase != .prepaint) return error.InvalidPhase;
                self.prepaint_state = try self.value.prepaint(f, f.layout.bounds(self.id), &self.request_state);
                self.phase = .prepainted;
            }
            fn paint(raw: *anyopaque, f: *Frame) !void {
                const self: *@This() = @ptrCast(@alignCast(raw));
                if (self.phase != .prepainted or f.phase != .paint) return error.InvalidPhase;
                try self.value.paint(f, f.layout.bounds(self.id), &self.request_state, &self.prepaint_state);
                self.phase = .painted;
            }
            const vtable = VTable{ .request = request, .prepaint = @This().prepaint, .paint = @This().paint };
        };
        const ptr = try frame.allocator().create(Drawable);
        ptr.* = .{ .value = value };
        return .{ .ptr = ptr, .vtable = &Drawable.vtable };
    }
    pub fn requestLayout(self: AnyElement, f: *Frame) !layout.LayoutId {
        return self.vtable.request(self.ptr, f);
    }
    pub fn prepaint(self: AnyElement, f: *Frame) !void {
        try self.vtable.prepaint(self.ptr, f);
    }
    pub fn paint(self: AnyElement, f: *Frame) !void {
        try self.vtable.paint(self.ptr, f);
    }
};

pub const Div = struct {
    pub const RequestLayoutState = void;
    pub const PrepaintState = g.Bounds;
    style: layout.Style = .{},
    children: []const AnyElement = &.{},
    /// Stable application-defined identifier for headless hit testing.
    id: ?u64 = null,

    pub fn requestLayout(self: *Div, f: *Frame) !LayoutRequest(void) {
        const ids = try f.allocator().alloc(layout.LayoutId, self.children.len);
        for (self.children, 0..) |child, i| ids[i] = try child.requestLayout(f);
        return .{ .id = try f.layout.request(self.style, ids), .state = {} };
    }
    pub fn prepaint(self: *Div, f: *Frame, bounds: g.Bounds, _: *void) !g.Bounds {
        const old_clip = f.clip;
        defer f.clip = old_clip;
        if (self.style.hidden) return old_clip;
        if (self.id) |id| try f.hitbox(id, bounds);
        if (self.style.clip) f.clip = bounds.intersect(old_clip);
        for (self.children) |child| try child.prepaint(f);
        return f.clip;
    }
    pub fn paint(self: *Div, f: *Frame, bounds: g.Bounds, _: *void, clip: *g.Bounds) !void {
        if (self.style.hidden) return;
        const old_clip = f.clip;
        defer f.clip = old_clip;
        f.clip = clip.*;
        if (self.style.background) |color| try f.scene.quad(f.allocator(), .{ .bounds = bounds, .color = color, .clip = clip.* });
        for (self.children) |child| try child.paint(f);
    }
};

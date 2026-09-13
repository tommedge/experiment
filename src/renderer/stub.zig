const std = @import("std");
const Scene = @import("../scene.zig").Scene;
const Size = @import("../geometry.zig").Size;

/// Headless backend. Retains an owned copy, never references frame-arena memory.
pub const Stub = struct {
    allocator: std.mem.Allocator,
    size: Size,
    scale: f32,
    presented_frames: usize = 0,
    scene: Scene = .{},

    pub fn init(allocator: std.mem.Allocator, size: Size, scale: f32) !Stub {
        return .{ .allocator = allocator, .size = size, .scale = scale };
    }
    pub fn deinit(self: *Stub) void {
        self.scene.deinit(self.allocator);
    }
    pub fn resize(self: *Stub, size: Size, scale: f32) !void {
        self.size = size;
        self.scale = scale;
    }
    pub fn submit(self: *Stub, scene: *const Scene) !void {
        try self.scene.primitives.ensureTotalCapacity(self.allocator, scene.primitives.items.len);
        self.scene.primitives.clearRetainingCapacity();
        self.scene.primitives.appendSliceAssumeCapacity(scene.primitives.items);
        self.presented_frames += 1;
    }
};

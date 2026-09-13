const std = @import("std");
const g = @import("geometry.zig");
pub const Quad = struct { bounds: g.Bounds, color: g.Color, clip: g.Bounds };
pub const Primitive = union(enum) { quad: Quad };
pub const Scene = struct {
    primitives: std.ArrayList(Primitive) = .empty,

    pub fn deinit(self: *Scene, allocator: std.mem.Allocator) void {
        self.primitives.deinit(allocator);
    }
    pub fn quad(self: *Scene, allocator: std.mem.Allocator, value: Quad) !void {
        try self.primitives.append(allocator, .{ .quad = value });
    }
};

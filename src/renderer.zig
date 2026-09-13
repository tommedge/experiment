const std = @import("std");
const g = @import("geometry.zig");
const Scene = @import("scene.zig").Scene;
pub const Stub = @import("renderer/stub.zig").Stub;
pub const Backend = switch (@import("build_options").backend) {
    .stub => Stub,
    .auto => @compileError("Build must resolve the platform backend"),
};
pub const Renderer = GenericRenderer(Backend);

/// Structural, comptime backend contract, following Ghostty's GenericRenderer.
/// A backend owns platform resources; submit must consume or copy the scene
/// before returning. GPU backends can copy into their own in-flight buffers.
pub fn GenericRenderer(comptime Implementation: type) type {
    return struct {
        const Self = @This();
        backend: Implementation,
        pub fn init(a: std.mem.Allocator, size: g.Size, scale: f32) !Self {
            return .{ .backend = try Implementation.init(a, size, scale) };
        }
        pub fn deinit(self: *Self) void {
            self.backend.deinit();
        }
        pub fn resize(self: *Self, size: g.Size, scale: f32) !void {
            try self.backend.resize(size, scale);
        }
        pub fn submit(self: *Self, scene: *const Scene) !void {
            try self.backend.submit(scene);
        }
    };
}

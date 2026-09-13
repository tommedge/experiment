const std = @import("std");
const g = @import("geometry.zig");
pub const Quad = struct { bounds: g.Bounds, color: g.Color, clip: g.Bounds };
/// Glyph at a logical baseline. Its generic text service is retained independently
/// of frame storage; rasterization and atlas placement happen in the renderer.
pub const Glyph = struct {
    system: *@import("text_system.zig").TextSystem,
    font_id: @import("text_system.zig").FontId,
    glyph_id: @import("text_system.zig").GlyphId,
    font_size: f32,
    position: g.Point,
    color: g.Color,
    clip: g.Bounds,
};
pub const Primitive = union(enum) {
    quad: Quad,
    glyph: Glyph,
    pub fn retain(self: Primitive) Primitive {
        if (self == .glyph) _ = self.glyph.system.retain();
        return self;
    }
    pub fn release(self: Primitive) void {
        if (self == .glyph) self.glyph.system.release();
    }
};
pub const Scene = struct {
    primitives: std.ArrayList(Primitive) = .empty,

    pub fn deinit(self: *Scene, allocator: std.mem.Allocator) void {
        for (self.primitives.items) |primitive| primitive.release();
        self.primitives.deinit(allocator);
    }
    pub fn quad(self: *Scene, allocator: std.mem.Allocator, value: Quad) !void {
        try self.primitives.append(allocator, .{ .quad = value });
    }
    pub fn glyph(self: *Scene, allocator: std.mem.Allocator, value: Glyph) !void {
        try self.appendPrimitives(allocator, &.{.{ .glyph = value }});
    }
    pub fn appendPrimitives(self: *Scene, a: std.mem.Allocator, primitives: []const Primitive) !void {
        try self.primitives.ensureUnusedCapacity(a, primitives.len);
        for (primitives) |primitive| self.primitives.appendAssumeCapacity(primitive.retain());
    }
    pub fn copyPrimitives(a: std.mem.Allocator, primitives: []const Primitive) ![]const Primitive {
        const copy = try a.dupe(Primitive, primitives);
        for (copy) |*primitive| primitive.* = primitive.retain();
        return copy;
    }
};

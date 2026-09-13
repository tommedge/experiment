const std = @import("std");
const g = @import("geometry.zig");
/// Fill and optional analytic border of one box. The GPU evaluates both edges
/// together so rounded, translucent borders blend with the background only once.
pub const Quad = struct {
    bounds: g.Bounds,
    color: g.Color,
    clip: g.Bounds,
    corner_radii: g.Corners = .{},
    border_widths: g.Edges = .{},
    border_color: g.Color = .{ .a = 0 },
    /// Invisible fills can still have visible outlines. Hitboxes are independent
    /// of scene primitives, so omitting an invisible quad does not disable input.
    pub fn isTransparent(self: Quad) bool {
        return self.color.a == 0 and (self.border_color.a == 0 or std.meta.eql(self.border_widths, g.Edges{}));
    }
};
/// Border inside a box, with already-snapped logical widths. Square borders use
/// non-overlapping strips; rounded borders become one transparent-fill analytic quad.
pub const Border = struct { bounds: g.Bounds, widths: g.Edges, color: g.Color, clip: g.Bounds, corner_radii: g.Corners = .{} };
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
        try value.corner_radii.validate();
        try value.border_widths.validateBorder();
        if (value.isTransparent()) return;
        var normalized = value;
        normalized.corner_radii = value.corner_radii.clamped(value.bounds.size);
        try self.primitives.append(allocator, .{ .quad = normalized });
    }
    /// Paints a styled box. Rounded fill/border share one analytic primitive;
    /// square boxes preserve the existing solid-quad fast path.
    pub fn box(self: *Scene, allocator: std.mem.Allocator, value: Quad) !void {
        try value.corner_radii.validate();
        try value.border_widths.validateBorder();
        if (value.corner_radii.any()) {
            if (value.color.a != 0 or (value.border_color.a != 0 and !std.meta.eql(value.border_widths, g.Edges{}))) try self.quad(allocator, value);
        } else {
            if (value.color.a != 0) try self.quad(allocator, .{ .bounds = value.bounds, .color = value.color, .clip = value.clip });
            try self.border(allocator, .{ .bounds = value.bounds, .widths = value.border_widths, .color = value.border_color, .clip = value.clip });
        }
    }
    pub fn border(self: *Scene, allocator: std.mem.Allocator, value: Border) !void {
        try value.widths.validateBorder();
        try value.corner_radii.validate();
        if (value.color.a == 0 or value.bounds.size.width <= 0 or value.bounds.size.height <= 0 or std.meta.eql(value.widths, g.Edges{})) return;
        if (value.corner_radii.any()) return self.quad(allocator, .{ .bounds = value.bounds, .color = .{ .a = 0 }, .clip = value.clip, .corner_radii = value.corner_radii, .border_widths = value.widths, .border_color = value.color });
        const b = value.bounds;
        const top = @min(value.widths.top, b.size.height);
        const bottom = @min(value.widths.bottom, b.size.height - top);
        const left = @min(value.widths.left, b.size.width);
        const right = @min(value.widths.right, b.size.width - left);
        const middle = b.size.height - top - bottom;
        const rectangles = [_]g.Bounds{
            .{ .origin = b.origin, .size = .{ .width = b.size.width, .height = top } },
            .{ .origin = .{ .x = b.origin.x, .y = b.origin.y + b.size.height - bottom }, .size = .{ .width = b.size.width, .height = bottom } },
            .{ .origin = .{ .x = b.origin.x, .y = b.origin.y + top }, .size = .{ .width = left, .height = middle } },
            .{ .origin = .{ .x = b.origin.x + b.size.width - right, .y = b.origin.y + top }, .size = .{ .width = right, .height = middle } },
        };
        try self.primitives.ensureUnusedCapacity(allocator, rectangles.len);
        for (rectangles) |rect| {
            const visible = rect.intersect(value.clip);
            if (visible.size.width <= 0 or visible.size.height <= 0) continue;
            self.primitives.appendAssumeCapacity(.{ .quad = .{ .bounds = rect, .clip = value.clip, .color = value.color } });
        }
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

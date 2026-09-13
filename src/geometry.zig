const std = @import("std");

pub const Point = struct { x: f32 = 0, y: f32 = 0 };
pub const Size = struct { width: f32, height: f32 };
/// Logical circular radii in clockwise order. Like GPUI's clamped style radii,
/// each corner is limited to half the smaller box dimension during painting.
pub const Corners = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,
    pub fn all(radius: f32) Corners {
        return .{ .top_left = radius, .top_right = radius, .bottom_right = radius, .bottom_left = radius };
    }
    pub fn validate(self: Corners) !void {
        inline for (std.meta.fields(Corners)) |field| {
            const radius = @field(self, field.name);
            if (!std.math.isFinite(radius) or radius < 0) return error.InvalidCornerRadius;
        }
    }
    pub fn any(self: Corners) bool {
        return self.top_left > 0 or self.top_right > 0 or self.bottom_right > 0 or self.bottom_left > 0;
    }
    pub fn clamped(self: Corners, size: Size) Corners {
        const limit = @max(0, @min(size.width, size.height) / 2);
        var result: Corners = .{};
        inline for (std.meta.fields(Corners)) |field| @field(result, field.name) = @min(@field(self, field.name), limit);
        return result;
    }
};
/// Logical per-edge distances shared by layout and drawing. Border snapping uses
/// GPUI's nearest-device-pixel rule, with half ties toward zero and a one-pixel
/// minimum for positive strokes. Zero stays zero.
pub const Edges = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    pub fn all(value: f32) Edges {
        return .{ .left = value, .top = value, .right = value, .bottom = value };
    }
    pub fn add(self: Edges, other: Edges) Edges {
        return .{ .left = self.left + other.left, .top = self.top + other.top, .right = self.right + other.right, .bottom = self.bottom + other.bottom };
    }
    pub fn validateBorder(self: Edges) !void {
        inline for (std.meta.fields(Edges)) |field| {
            const width = @field(self, field.name);
            if (!std.math.isFinite(width) or width < 0) return error.InvalidBorderWidth;
        }
    }
    pub fn snapped(self: Edges, scale: f32) !Edges {
        if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidScale;
        try self.validateBorder();
        var result: Edges = .{};
        inline for (std.meta.fields(Edges)) |field| {
            const width = @field(self, field.name);
            const pixels = width * scale;
            if (!std.math.isFinite(pixels)) return error.InvalidBorderWidth;
            const snapped_width = if (width == 0) 0 else @max(1, @ceil(pixels - 0.5)) / scale;
            if (!std.math.isFinite(snapped_width)) return error.InvalidBorderWidth;
            @field(result, field.name) = snapped_width;
        }
        return result;
    }
};
pub const Bounds = struct {
    origin: Point = .{},
    size: Size = .{ .width = 0, .height = 0 },

    pub fn contains(self: Bounds, p: Point) bool {
        return p.x >= self.origin.x and p.y >= self.origin.y and
            p.x < self.origin.x + self.size.width and p.y < self.origin.y + self.size.height;
    }

    pub fn intersect(a: Bounds, b: Bounds) Bounds {
        const x = @max(a.origin.x, b.origin.x);
        const y = @max(a.origin.y, b.origin.y);
        return .{ .origin = .{ .x = x, .y = y }, .size = .{
            .width = @max(0, @min(a.origin.x + a.size.width, b.origin.x + b.size.width) - x),
            .height = @max(0, @min(a.origin.y + a.size.height, b.origin.y + b.size.height) - y),
        } };
    }
    /// Shrinks a border box to its padding box, clamping exhausted dimensions.
    pub fn inset(self: Bounds, edges: Edges) Bounds {
        const left = @min(edges.left, self.size.width);
        const top = @min(edges.top, self.size.height);
        return .{ .origin = .{ .x = self.origin.x + left, .y = self.origin.y + top }, .size = .{
            .width = @max(0, self.size.width - left - edges.right),
            .height = @max(0, self.size.height - top - edges.bottom),
        } };
    }
};
/// Straight (unpremultiplied) linear RGBA, each channel in 0...1. Alpha controls
/// source-over transparency; the renderer premultiplies RGB before blending.
pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,
    pub const transparent: Color = .{ .a = 0 };
};

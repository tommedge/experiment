pub const Point = struct { x: f32 = 0, y: f32 = 0 };
pub const Size = struct { width: f32, height: f32 };
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
};
/// Linear RGBA, each channel in 0...1.
pub const Color = struct { r: f32 = 0, g: f32 = 0, b: f32 = 0, a: f32 = 1 };

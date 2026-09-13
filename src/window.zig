const std = @import("std");
const reactive = @import("app.zig");
const g = @import("geometry.zig");
const frame = @import("frame.zig");
const AnyElement = @import("element.zig").AnyElement;

pub const Window = WindowWithRenderer(@import("renderer.zig").Renderer);

/// The platform host calls drawIfNeeded after updates or an OS frame request.
/// No native window or GPU context is created in phase one.
pub fn WindowWithRenderer(comptime Renderer: type) type {
    return struct {
        const Self = @This();
        app: *reactive.App,
        root_id: reactive.EntityId,
        render: *const fn (*frame.Frame, reactive.EntityId) anyerror!AnyElement,
        renderer: Renderer,
        size: g.Size,
        scale: f32,
        dirty: bool = true,
        drawing: bool = false,
        dependencies: std.ArrayList(reactive.Dependency) = .empty,
        hitboxes: std.ArrayList(frame.Hitbox) = .empty,

        pub fn init(app: *reactive.App, root: anytype, size: g.Size, scale: f32) !Self {
            _ = try app.read(root);
            try validateSize(size, scale);
            const Adapter = struct {
                fn render(f: *frame.Frame, id: reactive.EntityId) !AnyElement {
                    return f.view(@TypeOf(root){ .app = f.app, .id = id });
                }
            };
            return .{ .app = app, .root_id = root.id, .render = Adapter.render, .renderer = try Renderer.init(app.allocator, size, scale), .size = size, .scale = scale };
        }
        pub fn deinit(self: *Self) void {
            self.hitboxes.deinit(self.app.allocator);
            self.dependencies.deinit(self.app.allocator);
            self.renderer.deinit();
        }
        pub fn invalidate(self: *Self) void {
            self.dirty = true;
        }
        pub fn resize(self: *Self, size: g.Size, scale: f32) !void {
            try validateSize(size, scale);
            try self.renderer.resize(size, scale);
            self.size = size;
            self.scale = scale;
            self.dirty = true;
        }
        pub fn needsDraw(self: *const Self) bool {
            if (self.dirty) return true;
            for (self.dependencies.items) |dep| {
                if (self.app.revision(dep.id) != dep.revision) return true;
            }
            return false;
        }
        pub fn drawIfNeeded(self: *Self) !bool {
            if (self.drawing or self.app.tracking != null or self.app.depth != 0 or self.app.flushing) return error.FrameDuringUpdate;
            try self.app.flush();
            if (!self.needsDraw()) return false;
            self.drawing = true;
            defer self.drawing = false;
            // On failure keep the previous scene, dependencies and hitboxes.
            self.dirty = true;
            var next = try frame.Frame.init(self.app, self.size, self.scale);
            defer next.deinit();
            var deps: std.ArrayList(reactive.Dependency) = .empty;
            defer deps.deinit(self.app.allocator);
            self.app.tracking = &deps;
            defer self.app.tracking = null;
            const root = try self.render(&next, self.root_id);
            try next.draw(root);
            try self.hitboxes.ensureTotalCapacity(self.app.allocator, next.hitboxes.items.len);
            try self.renderer.submit(&next.scene);
            std.mem.swap(std.ArrayList(reactive.Dependency), &deps, &self.dependencies);
            self.hitboxes.clearRetainingCapacity();
            self.hitboxes.appendSliceAssumeCapacity(next.hitboxes.items);
            self.dirty = false;
            return true;
        }
        /// Reverse paint order: the last painted hitbox wins.
        pub fn hitTest(self: *const Self, point: g.Point) ?u64 {
            var i = self.hitboxes.items.len;
            while (i > 0) {
                i -= 1;
                if (self.hitboxes.items[i].bounds.contains(point)) return self.hitboxes.items[i].id;
            }
            return null;
        }
    };
}

fn validateSize(size: g.Size, scale: f32) !void {
    if (!std.math.isFinite(size.width) or !std.math.isFinite(size.height) or size.width < 0 or size.height < 0) return error.InvalidSize;
    if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidScale;
}

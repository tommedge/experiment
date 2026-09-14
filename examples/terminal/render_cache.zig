const std = @import("std");
const ui = @import("zigui");

/// Example-local shaping cache: ASCII has direct slots; other graphemes use a
/// bounded hash table. Lines are retained independently of TextSystem's small LRU.
pub const Shapes = struct {
    allocator: std.mem.Allocator,
    ascii: [4][128]?*ui.LineLayout = @splat(@splat(null)),
    other: std.StringHashMapUnmanaged(*ui.LineLayout) = .empty,
    order: std.ArrayList([]const u8) = .empty,
    next_evict: usize = 0,
    scratch: std.ArrayList(u8) = .empty,
    hits: usize = 0,
    misses: usize = 0,
    const capacity = 1024;

    pub fn init(a: std.mem.Allocator) Shapes {
        return .{ .allocator = a };
    }
    pub fn clear(self: *Shapes) void {
        for (&self.ascii) |*style| for (style) |*slot| {
            if (slot.*) |line| line.release();
            slot.* = null;
        };
        var entries = self.other.iterator();
        while (entries.next()) |entry| {
            entry.value_ptr.*.release();
            self.allocator.free(entry.key_ptr.*);
        }
        self.other.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        self.next_evict = 0;
    }
    pub fn deinit(self: *Shapes) void {
        self.clear();
        self.other.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
    }
    /// Returns a borrowed line, valid until the next eviction/clear. The caller
    /// immediately emits value-only glyph descriptors; rows never store this pointer.
    pub fn get(self: *Shapes, fonts: *ui.TextSystem, font_ids: [4]ui.FontId, size: f32, style: usize, cp: u21, extra: []const u21) !*ui.LineLayout {
        if (cp < 128 and extra.len == 0) {
            if (self.ascii[style][cp]) |line| {
                self.hits += 1;
                return line;
            }
            const byte = [1]u8{@intCast(cp)};
            const line = try fonts.shapeLine(&byte, size, &.{.{ .len = 1, .font_id = font_ids[style] }});
            self.ascii[style][cp] = line;
            self.misses += 1;
            return line;
        }
        self.scratch.clearRetainingCapacity();
        try self.scratch.append(self.allocator, @intCast(style));
        try appendCodepoint(self.allocator, &self.scratch, cp);
        for (extra) |point| try appendCodepoint(self.allocator, &self.scratch, point);
        if (self.other.get(self.scratch.items)) |line| {
            self.hits += 1;
            return line;
        }
        const key = try self.allocator.dupe(u8, self.scratch.items);
        errdefer self.allocator.free(key);
        const bytes = key[1..];
        const line = try fonts.shapeLine(bytes, size, &.{.{ .len = bytes.len, .font_id = font_ids[style] }});
        errdefer line.release();
        try self.other.ensureUnusedCapacity(self.allocator, 1);
        if (self.order.items.len < capacity) {
            try self.order.append(self.allocator, key);
        } else {
            const old = self.order.items[self.next_evict];
            const removed = self.other.fetchRemove(old).?;
            removed.value.release();
            self.allocator.free(old);
            self.order.items[self.next_evict] = key;
            self.next_evict = (self.next_evict + 1) % capacity;
        }
        self.other.putAssumeCapacity(key, line);
        self.misses += 1;
        return line;
    }
};
fn appendCodepoint(a: std.mem.Allocator, bytes: *std.ArrayList(u8), cp: u21) !void {
    var buffer: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &buffer);
    try bytes.appendSlice(a, buffer[0..len]);
}

/// Row scenes own all primitive resources and use coordinates relative to the
/// row's origin. An update stages every dirty row before replacing any old data.
pub const Rows = struct {
    allocator: std.mem.Allocator,
    scenes: []ui.scene.Scene = &.{},
    /// Exact paint-input descriptions distinguish actual cell changes from
    /// Ghostty's conservative cursor-related dirty flags, without hash collisions.
    descriptions: [][]const u8 = &.{},
    scratch: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(Update) = .empty,
    rebuilt: usize = 0,
    reused: usize = 0,
    /// Temporary replacement ownership; cleared on both commit and rollback.
    const Update = struct { index: usize, scene: ui.scene.Scene, description: []const u8 };
    pub fn init(a: std.mem.Allocator) Rows {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Rows) void {
        for (self.scenes) |*scene| scene.deinit(self.allocator);
        self.allocator.free(self.scenes);
        for (self.descriptions) |description| self.allocator.free(description);
        self.allocator.free(self.descriptions);
        self.scratch.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }
    pub fn update(self: *Rows, dirty: []bool, full: bool, builder: anytype, scale: f32) !void {
        std.debug.assert(self.pending.items.len == 0);
        var resized: ?[]ui.scene.Scene = null;
        defer if (resized) |scenes| self.allocator.free(scenes);
        var resized_descriptions: ?[][]const u8 = null;
        defer if (resized_descriptions) |descriptions| self.allocator.free(descriptions);
        errdefer {
            for (self.pending.items) |*entry| {
                entry.scene.deinit(self.allocator);
                self.allocator.free(entry.description);
            }
            self.pending.clearRetainingCapacity();
        }
        const rebuild_all = full or dirty.len != self.scenes.len;
        if (dirty.len != self.scenes.len) {
            resized = try self.allocator.alloc(ui.scene.Scene, dirty.len);
            @memset(resized.?, .{});
            resized_descriptions = try self.allocator.alloc([]const u8, dirty.len);
            @memset(resized_descriptions.?, &.{});
        }
        for (dirty, 0..) |changed, y| {
            if (!rebuild_all and !changed) continue;
            self.scratch.clearRetainingCapacity();
            try builder.describeRow(self.allocator, y, &self.scratch);
            if (!rebuild_all and std.mem.eql(u8, self.scratch.items, self.descriptions[y])) continue;
            const description = try self.allocator.dupe(u8, self.scratch.items);
            var scene = builder.buildRow(self.allocator, y, scale) catch |err| {
                self.allocator.free(description);
                return err;
            };
            self.pending.append(self.allocator, .{ .index = y, .scene = scene, .description = description }) catch |err| {
                scene.deinit(self.allocator);
                self.allocator.free(description);
                return err;
            };
        }
        // No fallible operations after this point; failure above preserves rows
        // and Ghostty's dirty flags for a subsequent attempt.
        if (resized) |scenes| {
            for (self.scenes) |*scene| scene.deinit(self.allocator);
            self.allocator.free(self.scenes);
            for (self.descriptions) |description| self.allocator.free(description);
            self.allocator.free(self.descriptions);
            self.scenes = scenes;
            resized = null;
            self.descriptions = resized_descriptions.?;
            resized_descriptions = null;
        }
        for (self.pending.items) |entry| {
            self.scenes[entry.index].deinit(self.allocator);
            self.scenes[entry.index] = entry.scene;
            self.allocator.free(self.descriptions[entry.index]);
            self.descriptions[entry.index] = entry.description;
        }
        self.rebuilt += self.pending.items.len;
        self.reused += dirty.len - self.pending.items.len;
        self.pending.clearRetainingCapacity();
        @memset(dirty, false);
    }
    pub fn paint(self: *const Rows, f: *ui.Frame, origin: ui.geometry.Point, height: f32) !void {
        for (self.scenes, 0..) |row, y| {
            const offset = ui.geometry.Point{ .x = origin.x, .y = origin.y + @as(f32, @floatFromInt(y)) * height };
            try f.scene.primitives.ensureUnusedCapacity(f.allocator(), row.primitives.items.len);
            for (row.primitives.items) |primitive| {
                var shifted = primitive;
                switch (shifted) {
                    .quad => |*q| {
                        q.bounds.origin.x += offset.x;
                        q.bounds.origin.y += offset.y;
                        q.clip = translatedClip(q.clip, offset, f.clip);
                    },
                    .glyph => |*glyph| {
                        glyph.position.x += offset.x;
                        glyph.position.y += offset.y;
                        glyph.clip = translatedClip(glyph.clip, offset, f.clip);
                    },
                }
                f.scene.primitives.appendAssumeCapacity(shifted.retain());
            }
        }
    }
};
fn translatedClip(bounds: ui.geometry.Bounds, offset: ui.geometry.Point, clip: ui.geometry.Bounds) ui.geometry.Bounds {
    var result = bounds;
    result.origin.x += offset.x;
    result.origin.y += offset.y;
    return result.intersect(clip);
}

/// Drawing target shared by row construction and immediate cursor/preedit paint.
/// It exposes the small surface used by the example's geometric glyph helpers.
pub const Painter = struct {
    scene: *ui.scene.Scene,
    memory: std.mem.Allocator,
    scale: f32,
    clip: ui.geometry.Bounds,
    pub fn allocator(self: *Painter) std.mem.Allocator {
        return self.memory;
    }
};

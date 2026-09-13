const std = @import("std");
const text = @import("../text_system.zig");
const Glyph = @import("../scene.zig").Glyph;

/// Renderer-independent glyph identity. Float inputs are stored as bits for exact
/// hash/equality; service identity and generation prevent cross-font-system reuse.
pub const Key = struct {
    system: *text.TextSystem,
    generation: u64,
    font: u32,
    glyph: u32,
    size: u32,
    scale: u32,
    subpixel: [2]u8,
    pub fn init(glyph: Glyph, scale: f32) Key {
        const x = glyph.position.x * scale;
        const y = glyph.position.y * scale;
        return .{ .system = glyph.system, .generation = glyph.system.generation, .font = @intFromEnum(glyph.font_id), .glyph = glyph.glyph_id, .size = @bitCast(glyph.font_size), .scale = @bitCast(scale), .subpixel = .{ @intFromFloat(@floor((x - @floor(x)) * 4)), @intFromFloat(@floor((y - @floor(y)) * 4)) } };
    }
    pub fn params(self: Key) text.RenderGlyphParams {
        return .{ .font_id = @enumFromInt(self.font), .glyph_id = self.glyph, .font_size = @bitCast(self.size), .scale = @bitCast(self.scale), .subpixel = self.subpixel };
    }
};
/// Atlas location plus baseline-relative raster bounds; whitespace has no page.
pub const Tile = struct { page: ?usize, x: u32 = 0, y: u32 = 0, bounds: text.RasterBounds };
/// CPU backing for one monochrome or color page, uploaded by the GPU backend
/// when dirty. Shelf packing leaves transparent gutters between glyphs.
pub const Page = struct {
    side: u32,
    format: text.RasterFormat,
    pixels: []u8,
    x: u32 = 1,
    y: u32 = 1,
    row_height: u32 = 0,
    dirty: bool = true,
    pub fn channels(self: Page) usize {
        return if (self.format == .alpha8) 1 else 4;
    }
    fn reserve(self: *Page, width: u32, height: u32) ?struct { x: u32, y: u32 } {
        var x = self.x;
        var y = self.y;
        var row = self.row_height;
        if (x + width + 1 > self.side) {
            x = 1;
            y += row + 1;
            row = 0;
        }
        if (x + width + 1 > self.side or y + height + 1 > self.side) return null;
        self.x = x + width + 1;
        self.y = y;
        self.row_height = @max(row, height);
        return .{ .x = x, .y = y };
    }
};

/// Bounded raster cache shared by all glyph primitives in one renderer. Entries
/// retain their text service; clearing is safe because scenes store glyph IDs,
/// not atlas coordinates. A renderer can rebuild a full frame after eviction.
pub const Atlas = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(Key, Tile) = .empty,
    pages: std.ArrayList(Page) = .empty,
    page_side: u32 = 512,
    max_entries: u32 = 8192,
    max_bytes: usize = 32 * 1024 * 1024,
    bytes: usize = 0,
    pub fn init(a: std.mem.Allocator) Atlas {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Atlas) void {
        var keys = self.entries.keyIterator();
        while (keys.next()) |key| key.system.release();
        self.entries.deinit(self.allocator);
        for (self.pages.items) |page| self.allocator.free(page.pixels);
        self.pages.deinit(self.allocator);
    }
    pub fn clear(self: *Atlas) void {
        const a = self.allocator;
        const side = self.page_side;
        const limit = self.max_bytes;
        const entries_limit = self.max_entries;
        self.deinit();
        self.* = .{ .allocator = a, .page_side = side, .max_bytes = limit, .max_entries = entries_limit };
    }
    pub fn ensure(self: *Atlas, key: Key) !Tile {
        if (self.entries.get(key)) |tile| return tile;
        if (self.entries.count() >= self.max_entries) return error.AtlasFull;
        var bitmap = try key.system.rasterizeGlyph(self.allocator, key.params());
        defer bitmap.deinit(self.allocator);
        var tile = Tile{ .page = null, .bounds = bitmap.bounds };
        const width = bitmap.bounds.width;
        const height = bitmap.bounds.height;
        if (width > 4094 or height > 4094) return error.GlyphTooLarge;
        const channels: usize = if (bitmap.format == .alpha8) 1 else 4;
        if (bitmap.pixels.len != @as(usize, width) * height * channels) return error.InvalidGlyphBitmap;
        // Reserve the entry before mutating packing state, keeping allocation
        // failures retryable without leaking references or partially indexed tiles.
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        if (width > 0 and height > 0) {
            for (self.pages.items, 0..) |*page, i| {
                if (page.format != bitmap.format) continue;
                if (page.reserve(width, height)) |position| {
                    tile.page = i;
                    tile.x = position.x;
                    tile.y = position.y;
                    break;
                }
            }
            if (tile.page == null) {
                const side = @max(self.page_side, @max(width + 2, height + 2));
                const bytes = @as(usize, side) * side * channels;
                if (self.bytes >= self.max_bytes or bytes > self.max_bytes - self.bytes) return error.AtlasFull;
                const pixels = try self.allocator.alloc(u8, bytes);
                errdefer self.allocator.free(pixels);
                @memset(pixels, 0);
                tile.page = self.pages.items.len;
                try self.pages.append(self.allocator, .{ .side = side, .format = bitmap.format, .pixels = pixels });
                self.bytes += bytes;
                const position = self.pages.items[tile.page.?].reserve(width, height).?;
                tile.x = position.x;
                tile.y = position.y;
            }
            const page = &self.pages.items[tile.page.?];
            const stride = @as(usize, page.side) * channels;
            for (0..height) |row| {
                const dst = (tile.y + row) * stride + @as(usize, tile.x) * channels;
                const src = row * width * channels;
                @memcpy(page.pixels[dst..][0 .. width * channels], bitmap.pixels[src..][0 .. width * channels]);
            }
            page.dirty = true;
        }
        _ = key.system.retain();
        self.entries.putAssumeCapacity(key, tile);
        return tile;
    }
};

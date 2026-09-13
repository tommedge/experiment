const std = @import("std");
const g = @import("../geometry.zig");
const Scene = @import("../scene.zig").Scene;
const bridge = @import("../platform/macos/objc.zig");
const objc = bridge.objc;
const c = bridge.c;
const checked = bridge.checked;
const atlas_types = @import("atlas.zig");
extern fn MTLCreateSystemDefaultDevice() c.id;
const ClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
/// One solid or textured quad, matching the Metal shader's 64-byte layout.
const Instance = extern struct { origin: [2]f32, size: [2]f32, color: [4]f32, uv_origin: [2]f32 = .{ 0, 0 }, uv_size: [2]f32 = .{ 0, 0 }, mode: u32 = 0, padding: [3]u32 = .{ 0, 0, 0 } };
/// A contiguous scene range using the same atlas page; batching never changes order.
const Batch = struct { start: usize, count: usize, page: ?usize };
/// C-compatible texture upload region, kept private to the Metal implementation.
const Region = extern struct { origin: extern struct { x: usize = 0, y: usize = 0, z: usize = 0 } = .{}, size: extern struct { width: usize, height: usize, depth: usize = 1 } };

/// Per-surface Metal resources. Command buffers retain uploaded data. The initial
/// backend waits for GPU completion before presenting, bounding in-flight memory
/// and allowing submission errors to leave the previous drawable visible.
pub const Metal = struct {
    allocator: std.mem.Allocator,
    device: objc.Object,
    queue: objc.Object,
    pipeline: objc.Object,
    layer: objc.Object,
    size: g.Size,
    scale: f32,
    atlas: atlas_types.Atlas,
    textures: std.ArrayList(objc.Object) = .empty,
    sampler: objc.Object,
    white: objc.Object,

    pub fn init(a: std.mem.Allocator, size: g.Size, scale: f32) !Metal {
        const device = try checked(bridge.object(MTLCreateSystemDefaultDevice()));
        errdefer device.release();
        const queue = try checked(device.msgSend(objc.Object, "newCommandQueue", .{}));
        errdefer queue.release();
        var native_error: c.id = null;
        const library = try checked(device.msgSend(objc.Object, "newLibraryWithSource:options:error:", .{ bridge.string(@embedFile("quads.metal")), @as(c.id, null), &native_error }));
        defer library.release();
        const vertex = try checked(library.msgSend(objc.Object, "newFunctionWithName:", .{bridge.string("quad_vertex")}));
        defer vertex.release();
        const fragment = try checked(library.msgSend(objc.Object, "newFunctionWithName:", .{bridge.string("quad_fragment")}));
        defer fragment.release();
        const descriptor = bridge.new("MTLRenderPipelineDescriptor");
        defer descriptor.release();
        descriptor.msgSend(void, "setVertexFunction:", .{vertex});
        descriptor.msgSend(void, "setFragmentFunction:", .{fragment});
        const attachment = descriptor.msgSend(objc.Object, "colorAttachments", .{}).msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(usize, 0)});
        attachment.msgSend(void, "setPixelFormat:", .{@as(usize, 81)}); // BGRA8Unorm_sRGB
        attachment.msgSend(void, "setBlendingEnabled:", .{true});
        attachment.msgSend(void, "setSourceRGBBlendFactor:", .{@as(usize, 4)}); // source alpha
        attachment.msgSend(void, "setDestinationRGBBlendFactor:", .{@as(usize, 5)});
        attachment.msgSend(void, "setSourceAlphaBlendFactor:", .{@as(usize, 1)});
        attachment.msgSend(void, "setDestinationAlphaBlendFactor:", .{@as(usize, 5)});
        const pipeline = try checked(device.msgSend(objc.Object, "newRenderPipelineStateWithDescriptor:error:", .{ descriptor, &native_error }));
        errdefer pipeline.release();
        const layer = try checked(bridge.new("CAMetalLayer"));
        errdefer layer.release();
        layer.msgSend(void, "setDevice:", .{device});
        layer.msgSend(void, "setPixelFormat:", .{@as(usize, 81)});
        layer.msgSend(void, "setFramebufferOnly:", .{true});
        layer.msgSend(void, "setOpaque:", .{true});
        layer.msgSend(void, "setAllowsNextDrawableTimeout:", .{true});
        const sampler_descriptor = bridge.new("MTLSamplerDescriptor");
        defer sampler_descriptor.release();
        sampler_descriptor.msgSend(void, "setMinFilter:", .{@as(usize, 1)});
        sampler_descriptor.msgSend(void, "setMagFilter:", .{@as(usize, 1)});
        const sampler = try checked(device.msgSend(objc.Object, "newSamplerStateWithDescriptor:", .{sampler_descriptor}));
        errdefer sampler.release();
        const white_descriptor = objc.getClass("MTLTextureDescriptor").?.msgSend(objc.Object, "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ @as(usize, 10), @as(usize, 1), @as(usize, 1), false });
        const white = try checked(device.msgSend(objc.Object, "newTextureWithDescriptor:", .{white_descriptor}));
        errdefer white.release();
        const white_byte: u8 = 255;
        white.msgSend(void, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ Region{ .size = .{ .width = 1, .height = 1 } }, @as(usize, 0), &white_byte, @as(usize, 1) });
        var self = Metal{ .allocator = a, .device = device, .queue = queue, .pipeline = pipeline, .layer = layer, .size = size, .scale = scale, .atlas = .init(a), .sampler = sampler, .white = white };
        try self.resize(size, scale);
        return self;
    }
    pub fn deinit(self: *Metal) void {
        self.atlas.deinit();
        for (self.textures.items) |texture| texture.release();
        self.textures.deinit(self.allocator);
        self.sampler.release();
        self.white.release();
        self.layer.release();
        self.pipeline.release();
        self.queue.release();
        self.device.release();
    }
    pub fn resize(self: *Metal, size: g.Size, scale: f32) !void {
        self.size = size;
        self.scale = scale;
        self.layer.msgSend(void, "setContentsScale:", .{@as(f64, scale)});
        self.layer.msgSend(void, "setDrawableSize:", .{bridge.Size{ .width = @ceil(@as(f64, size.width) * scale), .height = @ceil(@as(f64, size.height) * scale) }});
    }
    pub fn submit(self: *Metal, scene: *const Scene) !void {
        if (self.size.width <= 0 or self.size.height <= 0) return error.SurfaceUnavailable;
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        self.prepareGlyphs(scene) catch |err| {
            if (err != error.AtlasFull) return err;
            // Evict historical entries and rebuild this entire frame before
            // creating instances, so no instance can reference a recycled tile.
            self.atlas.clear();
            for (self.textures.items) |texture| texture.release();
            self.textures.clearRetainingCapacity();
            try self.prepareGlyphs(scene);
        };
        try self.uploadAtlas();
        var instances: std.ArrayList(Instance) = .empty;
        defer instances.deinit(self.allocator);
        var batches: std.ArrayList(Batch) = .empty;
        defer batches.deinit(self.allocator);
        for (scene.primitives.items) |primitive| switch (primitive) {
            .quad => |q| {
                const bounds = q.bounds.intersect(q.clip).intersect(.{ .size = self.size });
                if (bounds.size.width <= 0 or bounds.size.height <= 0) continue;
                try instances.append(self.allocator, .{ .origin = .{ bounds.origin.x, bounds.origin.y }, .size = .{ bounds.size.width, bounds.size.height }, .color = .{ q.color.r, q.color.g, q.color.b, q.color.a } });
                try self.batch(&batches, instances.items.len - 1, null);
            },
            .glyph => |glyph| {
                const tile = self.atlas.entries.get(atlas_types.Key.init(glyph, self.scale)).?;
                const page_id = tile.page orelse continue;
                const page = self.atlas.pages.items[page_id];
                const origin = g.Point{ .x = (@floor(glyph.position.x * self.scale) + @as(f32, @floatFromInt(tile.bounds.x))) / self.scale, .y = (@floor(glyph.position.y * self.scale) + @as(f32, @floatFromInt(tile.bounds.y))) / self.scale };
                const raster = g.Bounds{ .origin = origin, .size = .{ .width = @as(f32, @floatFromInt(tile.bounds.width)) / self.scale, .height = @as(f32, @floatFromInt(tile.bounds.height)) / self.scale } };
                const bounds = raster.intersect(glyph.clip).intersect(.{ .size = self.size });
                if (bounds.size.width <= 0 or bounds.size.height <= 0) continue;
                const side: f32 = @floatFromInt(page.side);
                try instances.append(self.allocator, .{ .origin = .{ bounds.origin.x, bounds.origin.y }, .size = .{ bounds.size.width, bounds.size.height }, .color = .{ glyph.color.r, glyph.color.g, glyph.color.b, glyph.color.a }, .mode = if (page.format == .alpha8) 1 else 2, .uv_origin = .{ (@as(f32, @floatFromInt(tile.x)) + (bounds.origin.x - origin.x) * self.scale) / side, (@as(f32, @floatFromInt(tile.y)) + (bounds.origin.y - origin.y) * self.scale) / side }, .uv_size = .{ bounds.size.width * self.scale / side, bounds.size.height * self.scale / side } });
                try self.batch(&batches, instances.items.len - 1, page_id);
            },
        };
        const buffer = if (instances.items.len != 0) try checked(self.device.msgSend(objc.Object, "newBufferWithBytes:length:options:", .{ instances.items.ptr, instances.items.len * @sizeOf(Instance), @as(usize, 0) })) else bridge.object(null);
        defer if (buffer.value != null) buffer.release();
        const drawable = self.layer.msgSend(objc.Object, "nextDrawable", .{});
        if (drawable.value == null) return error.SurfaceUnavailable;
        const pass = objc.getClass("MTLRenderPassDescriptor").?.msgSend(objc.Object, "renderPassDescriptor", .{});
        const attachment = pass.msgSend(objc.Object, "colorAttachments", .{}).msgSend(objc.Object, "objectAtIndexedSubscript:", .{@as(usize, 0)});
        attachment.msgSend(void, "setTexture:", .{drawable.msgSend(objc.Object, "texture", .{})});
        attachment.msgSend(void, "setLoadAction:", .{@as(usize, 2)});
        attachment.msgSend(void, "setStoreAction:", .{@as(usize, 1)});
        attachment.msgSend(void, "setClearColor:", .{ClearColor{ .r = 0.025, .g = 0.025, .b = 0.03, .a = 1 }});
        const command = try checked(self.queue.msgSend(objc.Object, "commandBuffer", .{}));
        const encoder = try checked(command.msgSend(objc.Object, "renderCommandEncoderWithDescriptor:", .{pass}));
        encoder.msgSend(void, "setRenderPipelineState:", .{self.pipeline});
        if (instances.items.len != 0) {
            const viewport = [2]f32{ self.size.width, self.size.height };
            encoder.msgSend(void, "setVertexBuffer:offset:atIndex:", .{ buffer, @as(usize, 0), @as(usize, 0) });
            encoder.msgSend(void, "setVertexBytes:length:atIndex:", .{ &viewport, @as(usize, @sizeOf(@TypeOf(viewport))), @as(usize, 1) });
            encoder.msgSend(void, "setFragmentSamplerState:atIndex:", .{ self.sampler, @as(usize, 0) });
            for (batches.items) |draw| {
                encoder.msgSend(void, "setFragmentTexture:atIndex:", .{ if (draw.page) |page| self.textures.items[page] else self.white, @as(usize, 0) });
                encoder.msgSend(void, "setVertexBufferOffset:atIndex:", .{ draw.start * @sizeOf(Instance), @as(usize, 0) });
                encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @as(usize, 4), @as(usize, 0), @as(usize, 4), draw.count });
            }
        }
        encoder.msgSend(void, "endEncoding", .{});
        command.msgSend(void, "commit", .{});
        command.msgSend(void, "waitUntilCompleted", .{});
        if (command.msgSend(usize, "status", .{}) == 5) return error.GpuSubmissionFailed;
        drawable.msgSend(void, "present", .{});
    }
    fn batch(self: *Metal, batches: *std.ArrayList(Batch), index: usize, page: ?usize) !void {
        if (batches.items.len > 0 and batches.items[batches.items.len - 1].page == page) {
            batches.items[batches.items.len - 1].count += 1;
            return;
        }
        try batches.append(self.allocator, .{ .start = index, .count = 1, .page = page });
    }
    fn prepareGlyphs(self: *Metal, scene: *const Scene) !void {
        for (scene.primitives.items) |primitive| if (primitive == .glyph) {
            const glyph = primitive.glyph;
            if (!std.math.isFinite(glyph.position.x * self.scale) or !std.math.isFinite(glyph.position.y * self.scale)) return error.InvalidGlyphPosition;
            _ = try self.atlas.ensure(atlas_types.Key.init(glyph, self.scale));
        };
    }
    fn uploadAtlas(self: *Metal) !void {
        for (self.atlas.pages.items, 0..) |*page, i| {
            if (i >= self.textures.items.len) {
                const descriptor = objc.getClass("MTLTextureDescriptor").?.msgSend(objc.Object, "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
                    @as(usize, if (page.format == .alpha8) 10 else 70), @as(usize, page.side), @as(usize, page.side), false,
                });
                const texture = try checked(self.device.msgSend(objc.Object, "newTextureWithDescriptor:", .{descriptor}));
                errdefer texture.release();
                try self.textures.append(self.allocator, texture);
            }
            if (page.dirty) {
                self.textures.items[i].msgSend(void, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ Region{ .size = .{ .width = page.side, .height = page.side } }, @as(usize, 0), page.pixels.ptr, @as(usize, page.side) * page.channels() });
                page.dirty = false;
            }
        }
    }
};

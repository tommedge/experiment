const std = @import("std");
const g = @import("../geometry.zig");
const Scene = @import("../scene.zig").Scene;
const bridge = @import("../platform/macos/objc.zig");
const objc = bridge.objc;
const c = bridge.c;
const checked = bridge.checked;
extern fn MTLCreateSystemDefaultDevice() c.id;
const ClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
const Instance = extern struct { origin: [2]f32, size: [2]f32, color: [4]f32 };

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
        var self = Metal{ .allocator = a, .device = device, .queue = queue, .pipeline = pipeline, .layer = layer, .size = size, .scale = scale };
        try self.resize(size, scale);
        return self;
    }
    pub fn deinit(self: *Metal) void {
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
        var instances: std.ArrayList(Instance) = .empty;
        defer instances.deinit(self.allocator);
        for (scene.primitives.items) |primitive| switch (primitive) {
            .quad => |q| {
                const bounds = q.bounds.intersect(q.clip).intersect(.{ .size = self.size });
                if (bounds.size.width <= 0 or bounds.size.height <= 0) continue;
                try instances.append(self.allocator, .{ .origin = .{ bounds.origin.x, bounds.origin.y }, .size = .{ bounds.size.width, bounds.size.height }, .color = .{ q.color.r, q.color.g, q.color.b, q.color.a } });
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
            encoder.msgSend(void, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @as(usize, 4), @as(usize, 0), @as(usize, 4), instances.items.len });
        }
        encoder.msgSend(void, "endEncoding", .{});
        command.msgSend(void, "commit", .{});
        command.msgSend(void, "waitUntilCompleted", .{});
        if (command.msgSend(usize, "status", .{}) == 5) return error.GpuSubmissionFailed;
        drawable.msgSend(void, "present", .{});
    }
};

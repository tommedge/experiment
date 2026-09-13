const std = @import("std");
const g = @import("geometry.zig");
const Scene = @import("scene.zig").Scene;
const input = @import("input.zig");

pub const WindowOptions = struct {
    title: [:0]const u8 = "zigui",
    size: g.Size = .{ .width = 800, .height = 600 },
};
pub const Metrics = struct { size: g.Size, scale: f32 };
pub const RequestFrameOptions = struct { force_render: bool = false };
pub const Cursor = enum { arrow, pointing_hand, text, crosshair, resize_horizontal, resize_vertical };
pub const WindowCallbacks = struct {
    context: *anyopaque,
    request_frame: *const fn (*anyopaque, RequestFrameOptions) void,
    resize: *const fn (*anyopaque, Metrics) void,
    input: *const fn (*anyopaque, input.PlatformInput) input.DispatchEventResult,
    focus: ?*const fn (*anyopaque, bool) void = null,
    close: ?*const fn (*anyopaque) void = null,
};

/// Owning, type-erased native window. All methods and callbacks are UI-thread
/// only. Clear callbacks before destroying their context. Defer destruction
/// until outside callbacks (including close). The platform outlives its windows.
pub const PlatformWindow = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        deinit: *const fn (*anyopaque) void,
        metrics: *const fn (*anyopaque) Metrics,
        set_callbacks: *const fn (*anyopaque, ?WindowCallbacks) void,
        request_frame: *const fn (*anyopaque) void,
        draw: *const fn (*anyopaque, *const Scene) anyerror!void,
        set_title: *const fn (*anyopaque, [:0]const u8) void,
        set_cursor: *const fn (*anyopaque, Cursor) void,
        set_text_input_handler: *const fn (*anyopaque, ?input.TextInputHandler) void,
    };
    pub fn deinit(self: PlatformWindow) void {
        self.vtable.deinit(self.ptr);
    }
    pub fn metrics(self: PlatformWindow) Metrics {
        return self.vtable.metrics(self.ptr);
    }
    pub fn setCallbacks(self: PlatformWindow, cb: ?WindowCallbacks) void {
        self.vtable.set_callbacks(self.ptr, cb);
    }
    pub fn requestFrame(self: PlatformWindow) void {
        self.vtable.request_frame(self.ptr);
    }
    pub fn draw(self: PlatformWindow, scene: *const Scene) !void {
        try self.vtable.draw(self.ptr, scene);
    }
    pub fn setTitle(self: PlatformWindow, title: [:0]const u8) void {
        self.vtable.set_title(self.ptr, title);
    }
    pub fn setCursor(self: PlatformWindow, cursor: Cursor) void {
        self.vtable.set_cursor(self.ptr, cursor);
    }
    pub fn setTextInputHandler(self: PlatformWindow, handler: ?input.TextInputHandler) void {
        self.vtable.set_text_input_handler(self.ptr, handler);
    }
};

/// GPUI-style platform boundary. AppKit and Metal types never cross this API.
pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        deinit: *const fn (*anyopaque) void,
        open_window: *const fn (*anyopaque, WindowOptions) anyerror!PlatformWindow,
        run: *const fn (*anyopaque) void,
        quit: *const fn (*anyopaque) void,
        wake: *const fn (*anyopaque) void,
    };
    pub fn init(a: std.mem.Allocator) !Platform {
        return switch (@import("build_options").platform) {
            .macos => @import("platform/macos.zig").create(a),
            .stub => error.NativePlatformUnavailable,
            .auto => @compileError("Build must resolve platform"),
        };
    }
    pub fn deinit(self: Platform) void {
        self.vtable.deinit(self.ptr);
    }
    pub fn openWindow(self: Platform, options: WindowOptions) !PlatformWindow {
        return self.vtable.open_window(self.ptr, options);
    }
    pub fn run(self: Platform) void {
        self.vtable.run(self.ptr);
    }
    pub fn quit(self: Platform) void {
        self.vtable.quit(self.ptr);
    }
    /// Coalesced, asynchronous UI-loop wake; compatible with App.wakeup.schedule.
    pub fn wake(self: Platform) void {
        self.vtable.wake(self.ptr);
    }
    pub fn schedule(context: *anyopaque) void {
        const self: *Platform = @ptrCast(@alignCast(context));
        self.wake();
    }
};

/// Borrowed renderer adapter. Native surface owns the actual GPU backend.
pub const SurfaceRenderer = struct {
    surface: PlatformWindow,
    pub fn deinit(_: *SurfaceRenderer) void {}
    pub fn resize(_: *SurfaceRenderer, _: g.Size, _: f32) !void {}
    pub fn submit(self: *SurfaceRenderer, scene: *const Scene) !void {
        try self.surface.draw(scene);
    }
};

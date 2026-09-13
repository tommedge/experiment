const std = @import("std");
const ui = @import("app.zig");
const p = @import("platform.zig");
const input = @import("input.zig");

/// Stable-address bridge between reactive frames and a PlatformWindow.
pub const NativeWindow = struct {
    pub const ContentWindow = @import("window.zig").WindowWithRenderer(p.SurfaceRenderer);
    content: ContentWindow,
    surface: p.PlatformWindow,
    closed: bool = false,
    focused: bool = false,
    last_error: ?anyerror = null,
    on_input: ?struct {
        context: *anyopaque,
        dispatch: *const fn (*anyopaque, input.PlatformInput, ?u64) input.DispatchEventResult,
    } = null,

    pub fn create(app: *ui.App, platform: p.Platform, root: anytype, options: p.WindowOptions) !*NativeWindow {
        if (app.text_system == null) app.setTextSystem(platform.textSystem());
        const surface = try platform.openWindow(options);
        errdefer surface.deinit();
        const self = try app.allocator.create(NativeWindow);
        errdefer app.allocator.destroy(self);
        const metrics = surface.metrics();
        self.* = .{ .surface = surface, .content = try ContentWindow.initWithRenderer(app, root, metrics.size, metrics.scale, .{ .surface = surface }) };
        surface.setCallbacks(.{ .context = self, .request_frame = draw, .resize = resize, .input = dispatch, .focus = focus, .close = close });
        surface.requestFrame();
        return self;
    }
    pub fn destroy(self: *NativeWindow) void {
        const a = self.content.app.allocator;
        self.surface.setCallbacks(null);
        self.surface.setTextInputHandler(null);
        self.content.deinit();
        self.surface.deinit();
        a.destroy(self);
    }
    pub fn invalidate(self: *NativeWindow) void {
        self.content.invalidate();
        self.surface.requestFrame();
    }
    fn cast(ptr: *anyopaque) *NativeWindow {
        return @ptrCast(@alignCast(ptr));
    }
    fn draw(ptr: *anyopaque, options: p.RequestFrameOptions) void {
        const self = cast(ptr);
        self.surface.setTextInputHandler(null);
        defer self.surface.setTextInputHandler(self.content.focusedTextInput());
        if (options.force_render) self.content.invalidate();
        _ = self.content.drawIfNeeded() catch |err| {
            self.last_error = err;
            return;
        };
        self.last_error = null;
    }
    fn resize(ptr: *anyopaque, metrics: p.Metrics) void {
        const self = cast(ptr);
        self.content.resize(metrics.size, metrics.scale) catch |err| {
            self.last_error = err;
        };
    }
    fn dispatch(ptr: *anyopaque, event: input.PlatformInput) input.DispatchEventResult {
        const self = cast(ptr);
        defer self.surface.setTextInputHandler(self.content.focusedTextInput());
        const result = self.content.dispatchInput(event) catch |err| {
            self.last_error = err;
            return .{ .handled = true };
        };
        if (result.handled) return result;
        const target = if (event.position()) |point| self.content.hitTest(point) else null;
        if (self.on_input) |handler| return handler.dispatch(handler.context, event, target);
        return .{};
    }
    fn focus(ptr: *anyopaque, active: bool) void {
        cast(ptr).focused = active;
    }
    fn close(ptr: *anyopaque) void {
        cast(ptr).closed = true;
    }
};

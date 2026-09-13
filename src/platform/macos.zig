const std = @import("std");
const p = @import("../platform.zig");
const input = @import("../input.zig");
const bridge = @import("macos/objc.zig");
const objc = bridge.objc;
const c = bridge.c;
const object = bridge.object;
const Metal = @import("../renderer/metal.zig").Metal;
const Range = extern struct { location: c_ulong, length: c_ulong };
const not_found: usize = @intCast(std.math.maxInt(isize));

const MacPlatform = struct {
    allocator: std.mem.Allocator,
    application: objc.Object,
    windows: std.ArrayList(*MacWindow) = .empty,
    running: bool = false,
    wake_pending: bool = false,
    fn cast(ptr: *anyopaque) *MacPlatform {
        return @ptrCast(@alignCast(ptr));
    }
    fn deinit(ptr: *anyopaque) void {
        const self = cast(ptr);
        std.debug.assert(self.windows.items.len == 0);
        self.windows.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    fn wake(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.wake_pending) return;
        self.wake_pending = true;
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const event = objc.getClass("NSEvent").?.msgSend(objc.Object, "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
            @as(usize, 15), bridge.Point{ .x = 0, .y = 0 }, @as(usize, 0), @as(f64, 0), @as(isize, 0), @as(c.id, null), @as(c_short, 0), @as(isize, 0), @as(isize, 0),
        });
        self.application.msgSend(void, "postEvent:atStart:", .{ event, false });
    }
    fn quit(ptr: *anyopaque) void {
        cast(ptr).running = false;
        wake(ptr);
    }
    fn run(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.running = true;
        self.application.msgSend(void, "finishLaunching", .{});
        while (self.running) {
            var pool = objc.AutoreleasePool.init();
            defer pool.deinit();
            var open = false;
            for (self.windows.items) |window| {
                if (window.closed) continue;
                open = true;
                window.syncMetrics();
                if (window.callbacks) |cb| cb.request_frame(cb.context, .{});
            }
            if (!open or !self.running) break;
            self.application.msgSend(void, "updateWindows", .{});
            const until = objc.getClass("NSDate").?.msgSend(objc.Object, "distantFuture", .{});
            const event = self.application.msgSend(objc.Object, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ @as(usize, std.math.maxInt(usize)), until, bridge.string("kCFRunLoopDefaultMode"), true });
            self.wake_pending = false;
            if (event.value != null) self.application.msgSend(void, "sendEvent:", .{event});
        }
        self.running = false;
    }
    fn openWindow(ptr: *anyopaque, options: p.WindowOptions) !p.PlatformWindow {
        const self = cast(ptr);
        if (!std.math.isFinite(options.size.width) or !std.math.isFinite(options.size.height) or options.size.width <= 0 or options.size.height <= 0) return error.InvalidSize;
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const state = try self.allocator.create(MacWindow);
        errdefer self.allocator.destroy(state);
        const rect = bridge.Rect{ .size = .{ .width = options.size.width, .height = options.size.height } };
        const window = try bridge.checked(objc.getClass("NSWindow").?.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{ rect, @as(usize, 15), @as(usize, 2), false }));
        errdefer window.release();
        window.msgSend(void, "setReleasedWhenClosed:", .{false});
        const view = try bridge.checked(objc.getClass("ZiguiMetalView").?.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithFrame:", .{rect}));
        errdefer view.release();
        const delegate = try bridge.checked(bridge.new("ZiguiWindowDelegate"));
        errdefer delegate.release();
        const scale: f32 = @floatCast(window.msgSend(f64, "backingScaleFactor", .{}));
        var renderer = try Metal.init(self.allocator, options.size, scale);
        errdefer renderer.deinit();
        try self.windows.append(self.allocator, state);
        state.* = .{ .platform = self, .window = window, .view = view, .delegate = delegate, .renderer = renderer, .current = .{ .size = options.size, .scale = scale } };
        setState(view, state);
        setState(delegate, state);
        window.msgSend(void, "setDelegate:", .{delegate});
        window.msgSend(void, "setTitle:", .{bridge.string(options.title)});
        view.msgSend(void, "setLayer:", .{renderer.layer});
        view.msgSend(void, "setWantsLayer:", .{true});
        view.msgSend(void, "setAutoresizingMask:", .{@as(usize, 18)});
        window.msgSend(void, "setContentView:", .{view});
        window.msgSend(void, "setAcceptsMouseMovedEvents:", .{true});
        const tracking = objc.getClass("NSTrackingArea").?.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithRect:options:owner:userInfo:", .{ rect, @as(usize, 1 | 2 | 64 | 512), view, @as(c.id, null) });
        view.msgSend(void, "addTrackingArea:", .{tracking});
        tracking.release();
        window.msgSend(void, "center", .{});
        window.msgSend(void, "makeKeyAndOrderFront:", .{@as(c.id, null)});
        _ = window.msgSend(bool, "makeFirstResponder:", .{view});
        self.application.msgSend(void, "activateIgnoringOtherApps:", .{true});
        return .{ .ptr = state, .vtable = &MacWindow.vtable };
    }
    const vtable: p.Platform.VTable = .{ .deinit = deinit, .open_window = openWindow, .run = run, .quit = quit, .wake = wake };
};

const MacWindow = struct {
    platform: *MacPlatform,
    window: objc.Object,
    view: objc.Object,
    delegate: objc.Object,
    renderer: Metal,
    current: p.Metrics,
    callbacks: ?p.WindowCallbacks = null,
    closed: bool = false,
    marked_length: usize = 0,
    selection: Range = .{ .location = 0, .length = 0 },
    text_input_handler: ?input.TextInputHandler = null,
    fn cast(ptr: *anyopaque) *MacWindow {
        return @ptrCast(@alignCast(ptr));
    }
    fn deinit(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.callbacks = null;
        setState(self.view, null);
        setState(self.delegate, null);
        self.window.msgSend(void, "setDelegate:", .{@as(c.id, null)});
        self.window.msgSend(void, "close", .{});
        self.view.msgSend(void, "setLayer:", .{@as(c.id, null)});
        self.renderer.deinit();
        self.view.release();
        self.delegate.release();
        self.window.release();
        for (self.platform.windows.items, 0..) |w, i| if (w == self) {
            _ = self.platform.windows.orderedRemove(i);
            break;
        };
        self.platform.allocator.destroy(self);
    }
    fn metrics(ptr: *anyopaque) p.Metrics {
        return cast(ptr).current;
    }
    fn setCallbacks(ptr: *anyopaque, cb: ?p.WindowCallbacks) void {
        const self = cast(ptr);
        self.callbacks = cb;
        if (cb) |callbacks| if (callbacks.focus) |f| f(callbacks.context, self.window.msgSend(bool, "isKeyWindow", .{}));
    }
    fn requestFrame(ptr: *anyopaque) void {
        MacPlatform.wake(cast(ptr).platform);
    }
    fn draw(ptr: *anyopaque, scene: *const @import("../scene.zig").Scene) !void {
        const self = cast(ptr);
        if (self.closed or self.window.msgSend(bool, "isMiniaturized", .{})) return error.SurfaceUnavailable;
        try self.renderer.submit(scene);
    }
    fn setTitle(ptr: *anyopaque, title: [:0]const u8) void {
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        cast(ptr).window.msgSend(void, "setTitle:", .{bridge.string(title)});
    }
    fn setTextInputHandler(ptr: *anyopaque, handler: ?input.TextInputHandler) void {
        cast(ptr).text_input_handler = handler;
    }
    fn setCursor(_: *anyopaque, cursor: p.Cursor) void {
        const cls = objc.getClass("NSCursor").?;
        const native = switch (cursor) {
            .arrow => cls.msgSend(objc.Object, "arrowCursor", .{}),
            .pointing_hand => cls.msgSend(objc.Object, "pointingHandCursor", .{}),
            .text => cls.msgSend(objc.Object, "IBeamCursor", .{}),
            .crosshair => cls.msgSend(objc.Object, "crosshairCursor", .{}),
            .resize_horizontal => cls.msgSend(objc.Object, "resizeLeftRightCursor", .{}),
            .resize_vertical => cls.msgSend(objc.Object, "resizeUpDownCursor", .{}),
        };
        native.msgSend(void, "set", .{});
    }
    fn syncMetrics(self: *MacWindow) void {
        const bounds = self.view.msgSend(bridge.Rect, "bounds", .{});
        const next = p.Metrics{ .size = .{ .width = @floatCast(bounds.size.width), .height = @floatCast(bounds.size.height) }, .scale = @floatCast(self.window.msgSend(f64, "backingScaleFactor", .{})) };
        if (std.meta.eql(next, self.current)) return;
        self.current = next;
        self.renderer.resize(next.size, next.scale) catch unreachable;
        if (self.callbacks) |cb| cb.resize(cb.context, next);
    }
    fn emit(self: *MacWindow, event: input.PlatformInput) input.DispatchEventResult {
        if (self.callbacks) |cb| return cb.input(cb.context, event);
        return .{};
    }
    const vtable: p.PlatformWindow.VTable = .{ .deinit = deinit, .metrics = metrics, .set_callbacks = setCallbacks, .request_frame = requestFrame, .draw = draw, .set_title = setTitle, .set_cursor = setCursor, .set_text_input_handler = setTextInputHandler };
};

fn setState(obj: objc.Object, state: ?*MacWindow) void {
    obj.setInstanceVariable("zigState", object(@ptrCast(state)));
}
fn getState(id: c.id) ?*MacWindow {
    return @ptrCast(@alignCast(object(id).getInstanceVariable("zigState").value));
}
fn yes(_: c.id, _: c.SEL) callconv(.c) bool {
    return true;
}
fn firstMouse(_: c.id, _: c.SEL, _: c.id) callconv(.c) bool {
    return true;
}
fn modifiers(flags: usize) input.Modifiers {
    return .{ .caps_lock = flags & (1 << 16) != 0, .shift = flags & (1 << 17) != 0, .control = flags & (1 << 18) != 0, .alt = flags & (1 << 19) != 0, .command = flags & (1 << 20) != 0, .function = flags & (1 << 23) != 0 };
}
fn phase(value: usize) input.ScrollPhase {
    if (value & 16 != 0) return .cancelled;
    if (value & 8 != 0) return .ended;
    if (value & 1 != 0) return .began;
    if (value & 4 != 0) return .changed;
    if (value & 32 != 0) return .may_begin;
    return .none;
}
fn mouse(id: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const self = getState(id) orelse return;
    const event = object(event_id);
    const point = self.view.msgSend(bridge.Point, "convertPoint:fromView:", .{ event.msgSend(bridge.Point, "locationInWindow", .{}), @as(c.id, null) });
    const kind = event.msgSend(usize, "type", .{});
    const flags = modifiers(event.msgSend(usize, "modifierFlags", .{}));
    const position = @import("../geometry.zig").Point{ .x = @floatCast(point.x), .y = @floatCast(point.y) };
    if (kind == 22) {
        _ = self.emit(.{ .scroll = .{ .position = position, .delta = .{ .x = @floatCast(event.msgSend(f64, "scrollingDeltaX", .{})), .y = @floatCast(event.msgSend(f64, "scrollingDeltaY", .{})) }, .precise = event.msgSend(bool, "hasPreciseScrollingDeltas", .{}), .modifiers = flags, .phase = phase(event.msgSend(usize, "phase", .{})), .momentum_phase = phase(event.msgSend(usize, "momentumPhase", .{})) } });
        return;
    }
    const button: input.MouseButton = switch (event.msgSend(isize, "buttonNumber", .{})) {
        0 => .left,
        1 => .right,
        2 => .middle,
        3 => .back,
        4 => .forward,
        else => .other,
    };
    const is_button = switch (kind) {
        1, 2, 3, 4, 6, 7, 25, 26, 27 => true,
        else => false,
    };
    const value = input.MouseEvent{ .position = position, .modifiers = flags, .button = if (is_button) button else null, .click_count = if (is_button) @intCast(@max(0, event.msgSend(isize, "clickCount", .{}))) else 0 };
    _ = self.emit(switch (kind) {
        1, 3, 25 => .{ .mouse_down = value },
        2, 4, 26 => .{ .mouse_up = value },
        9 => .{ .mouse_exit = value },
        else => .{ .mouse_move = value },
    });
}
fn utf8(str: objc.Object) []const u8 {
    if (str.value == null) return "";
    const bytes = str.msgSend(?[*]const u8, "UTF8String", .{}) orelse return "";
    return bytes[0..str.msgSend(usize, "lengthOfBytesUsingEncoding:", .{@as(usize, 4)})];
}
fn keyName(code: u16, characters: []const u8) []const u8 {
    return switch (code) {
        36, 76 => "enter",
        48 => "tab",
        49 => "space",
        51 => "backspace",
        53 => "escape",
        115 => "home",
        116 => "pageup",
        117 => "delete",
        119 => "end",
        121 => "pagedown",
        123 => "left",
        124 => "right",
        125 => "down",
        126 => "up",
        122 => "f1",
        120 => "f2",
        99 => "f3",
        118 => "f4",
        96 => "f5",
        97 => "f6",
        98 => "f7",
        100 => "f8",
        101 => "f9",
        109 => "f10",
        103 => "f11",
        111 => "f12",
        else => characters,
    };
}
fn key(id: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const self = getState(id) orelse return;
    const event = object(event_id);
    const flags = modifiers(event.msgSend(usize, "modifierFlags", .{}));
    const kind = event.msgSend(usize, "type", .{});
    if (kind == 12) {
        _ = self.emit(.{ .modifiers_changed = flags });
        return;
    }
    const code = event.msgSend(u16, "keyCode", .{});
    const value = input.KeyEvent{ .key_code = code, .key = keyName(code, utf8(event.msgSend(objc.Object, "charactersIgnoringModifiers", .{}))), .modifiers = flags, .is_repeat = event.msgSend(bool, "isARepeat", .{}) };
    const result = self.emit(if (kind == 10) .{ .key_down = value } else .{ .key_up = value });
    if (kind == 10 and !result.handled and !flags.command and !flags.control) {
        const events = objc.getClass("NSArray").?.msgSend(objc.Object, "arrayWithObject:", .{event});
        self.view.msgSend(void, "interpretKeyEvents:", .{events});
    }
}
fn plainText(value: c.id) objc.Object {
    const obj = object(value);
    return if (obj.msgSend(bool, "isKindOfClass:", .{objc.getClass("NSAttributedString").?})) obj.msgSend(objc.Object, "string", .{}) else obj;
}
fn insertText(id: c.id, _: c.SEL, text: c.id, replacement: Range) callconv(.c) void {
    const self = getState(id) orelse return;
    self.marked_length = 0;
    _ = self.emit(.{ .text = .{ .text = utf8(plainText(text)), .replacement = portableRange(replacement) } });
}
fn setMarkedText(id: c.id, _: c.SEL, text: c.id, selected: Range, replacement: Range) callconv(.c) void {
    const self = getState(id) orelse return;
    const str = plainText(text);
    self.marked_length = str.msgSend(usize, "length", .{});
    self.selection = selected;
    _ = self.emit(.{ .marked_text = .{ .text = utf8(str), .selection = .{ .location = selected.location, .length = selected.length }, .replacement = if (replacement.location == not_found) null else .{ .location = replacement.location, .length = replacement.length } } });
}
fn unmark(id: c.id, _: c.SEL) callconv(.c) void {
    if (getState(id)) |self| {
        self.marked_length = 0;
        _ = self.emit(.unmark_text);
    }
}
fn hasMarked(id: c.id, _: c.SEL) callconv(.c) bool {
    return markedRange(id, null).location != not_found;
}
fn portableRange(range: Range) ?input.TextRange {
    return if (range.location == not_found) null else .{ .location = range.location, .length = range.length };
}
fn nativeRange(range: ?input.TextRange) Range {
    return if (range) |r| .{ .location = r.location, .length = r.length } else .{ .location = not_found, .length = 0 };
}
fn markedRange(id: c.id, _: c.SEL) callconv(.c) Range {
    if (getState(id)) |self| if (self.text_input_handler) |handler| return nativeRange(handler.marked_range(handler.context));
    return if (getState(id)) |self| .{ .location = if (self.marked_length > 0) 0 else not_found, .length = self.marked_length } else .{ .location = not_found, .length = 0 };
}
fn selectedRange(id: c.id, _: c.SEL) callconv(.c) Range {
    if (getState(id)) |self| if (self.text_input_handler) |handler| return nativeRange(handler.selected_range(handler.context));
    return if (getState(id)) |self| self.selection else .{ .location = not_found, .length = 0 };
}
fn attributes(_: c.id, _: c.SEL) callconv(.c) c.id {
    return objc.getClass("NSArray").?.msgSend(objc.Object, "array", .{}).value;
}
fn substring(id: c.id, _: c.SEL, range: Range, actual: ?*Range) callconv(.c) c.id {
    if (actual) |out| out.* = .{ .location = not_found, .length = 0 };
    const self = getState(id) orelse return null;
    const handler = self.text_input_handler orelse return null;
    const text = handler.text_for_range(handler.context, portableRange(range) orelse return null) orelse return null;
    if (actual) |out| out.* = range;
    const result = objc.getClass("NSAttributedString").?.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithString:", .{bridge.string(text)});
    return result.msgSend(objc.Object, "autorelease", .{}).value;
}
fn characterIndex(id: c.id, _: c.SEL, point: bridge.Point) callconv(.c) c_ulong {
    const self = getState(id) orelse return not_found;
    const handler = self.text_input_handler orelse return not_found;
    const window_point = self.window.msgSend(bridge.Point, "convertPointFromScreen:", .{point});
    const local = self.view.msgSend(bridge.Point, "convertPoint:fromView:", .{ window_point, @as(c.id, null) });
    return handler.character_index(handler.context, .{ .x = @floatCast(local.x), .y = @floatCast(local.y) }) orelse not_found;
}
fn firstRect(id: c.id, _: c.SEL, range: Range, actual: ?*Range) callconv(.c) bridge.Rect {
    if (actual) |out| out.* = range;
    const self = getState(id) orelse return .{ .size = .{ .width = 0, .height = 0 } };
    var local = bridge.Rect{ .size = .{ .width = 1, .height = 20 } };
    if (self.text_input_handler) |handler| {
        if (portableRange(range)) |r| if (handler.bounds_for_range(handler.context, r)) |bounds| {
            local = .{ .origin = .{ .x = bounds.origin.x, .y = bounds.origin.y }, .size = .{ .width = bounds.size.width, .height = bounds.size.height } };
        };
    }
    const rect = self.view.msgSend(bridge.Rect, "convertRect:toView:", .{ local, @as(c.id, null) });
    return self.window.msgSend(bridge.Rect, "convertRectToScreen:", .{rect});
}
fn command(_: c.id, _: c.SEL, _: c.SEL) callconv(.c) void {}
fn changed(id: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    if (getState(id)) |self| {
        self.syncMetrics();
        // AppKit enters a nested event loop during live resize.
        if (self.callbacks) |cb| cb.request_frame(cb.context, .{ .force_render = true });
        MacPlatform.wake(self.platform);
    }
}
fn close(id: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    if (getState(id)) |self| {
        self.closed = true;
        if (self.callbacks) |cb| if (cb.close) |f| f(cb.context);
        MacPlatform.wake(self.platform);
    }
}
fn focus(id: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    if (getState(id)) |self| {
        if (self.callbacks) |cb| if (cb.focus) |f| f(cb.context, self.window.msgSend(bool, "isKeyWindow", .{}));
    }
}
fn registerClasses() !void {
    if (objc.getClass("ZiguiMetalView") != null) return;
    const view = objc.allocateClassPair(objc.getClass("NSView").?, "ZiguiMetalView") orelse return error.NativeClassRegistrationFailed;
    if (c.class_addIvar(view.value, "zigState", @sizeOf(usize), @intCast(@ctz(@as(usize, @alignOf(usize)))), "^v") == 0) return error.NativeClassRegistrationFailed;
    inline for (.{
        .{ "isFlipped", yes },                                     .{ "acceptsFirstResponder", yes },                                   .{ "acceptsFirstMouse:", firstMouse },
        .{ "keyDown:", key },                                      .{ "keyUp:", key },                                                  .{ "flagsChanged:", key },
        .{ "insertText:replacementRange:", insertText },           .{ "setMarkedText:selectedRange:replacementRange:", setMarkedText }, .{ "unmarkText", unmark },
        .{ "hasMarkedText", hasMarked },                           .{ "markedRange", markedRange },                                     .{ "selectedRange", selectedRange },
        .{ "validAttributesForMarkedText", attributes },           .{ "attributedSubstringForProposedRange:actualRange:", substring },  .{ "characterIndexForPoint:", characterIndex },
        .{ "firstRectForCharacterRange:actualRange:", firstRect }, .{ "doCommandBySelector:", command },
    }) |method| if (!view.addMethod(method[0], method[1])) return error.NativeClassRegistrationFailed;
    inline for (.{ "mouseDown:", "mouseUp:", "mouseMoved:", "mouseDragged:", "rightMouseDown:", "rightMouseUp:", "rightMouseDragged:", "otherMouseDown:", "otherMouseUp:", "otherMouseDragged:", "mouseEntered:", "mouseExited:", "scrollWheel:" }) |name| if (!view.addMethod(name, mouse)) return error.NativeClassRegistrationFailed;
    if (c.objc_getProtocol("NSTextInputClient")) |protocol| _ = c.class_addProtocol(view.value, protocol);
    objc.registerClassPair(view);
    const delegate = objc.allocateClassPair(objc.getClass("NSObject").?, "ZiguiWindowDelegate") orelse return error.NativeClassRegistrationFailed;
    if (c.class_addIvar(delegate.value, "zigState", @sizeOf(usize), @intCast(@ctz(@as(usize, @alignOf(usize)))), "^v") == 0) return error.NativeClassRegistrationFailed;
    inline for (.{ .{ "windowDidResize:", changed }, .{ "windowDidChangeBackingProperties:", changed }, .{ "windowDidDeminiaturize:", changed }, .{ "windowWillClose:", close }, .{ "windowDidBecomeKey:", focus }, .{ "windowDidResignKey:", focus } }) |method| if (!delegate.addMethod(method[0], method[1])) return error.NativeClassRegistrationFailed;
    objc.registerClassPair(delegate);
}
pub fn create(a: std.mem.Allocator) !p.Platform {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    if (!objc.getClass("NSThread").?.msgSend(bool, "isMainThread", .{})) return error.MainThreadRequired;
    try registerClasses();
    const application = objc.getClass("NSApplication").?.msgSend(objc.Object, "sharedApplication", .{});
    _ = application.msgSend(bool, "setActivationPolicy:", .{@as(isize, 0)});
    const self = try a.create(MacPlatform);
    self.* = .{ .allocator = a, .application = application };
    return .{ .ptr = self, .vtable = &MacPlatform.vtable };
}

test "macOS modifier flags and scroll phases" {
    try std.testing.expectEqual(input.Modifiers{ .shift = true, .command = true }, modifiers((1 << 17) | (1 << 20)));
    try std.testing.expectEqual(input.ScrollPhase.cancelled, phase(16));
    try std.testing.expectEqual(input.ScrollPhase.ended, phase(8));
}

test "native key binding reaches a focused listener retained by cached subtree replay" {
    const ui = @import("../root.zig");
    const Increment = struct {};
    const Counter = struct {
        platform: p.Platform,
        focus: ui.FocusHandle,
        renders: *usize,
        value: u32 = 1,
        pub fn render(self: *const @This(), f: *ui.Frame, cx: *ui.Context(@This())) !ui.AnyElement {
            self.renders.* += 1;
            return f.div(.{
                .focus = self.focus,
                .key_context = "Counter",
                .id = 1,
                .listeners = &.{try f.entityActionListener(cx.entity, Increment, increment)},
                .bindings = &.{try f.bindKey("space", .{}, "Counter", Increment{})},
                .style = .{ .width = .{ .px = @as(f32, @floatFromInt(self.value)) * 10 }, .height = .{ .px = 20 }, .background = .{ .r = 0.7 } },
            });
        }
        fn increment(self: *@This(), _: *const Increment, phase_value: ui.DispatchPhase, cx: *ui.Context(@This()), ec: *ui.EventContext) !void {
            if (phase_value != .bubble) return;
            self.value += 1;
            try cx.notify();
            ec.stopPropagation();
            self.platform.quit();
        }
    };
    const Root = struct {
        child: ui.Entity(Counter),
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            return f.cachedView(self.child, .{ .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } } });
        }
        fn notify(_: *@This(), cx: *ui.Context(@This())) !void {
            try cx.notify();
        }
    };
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var application = ui.App.init(std.testing.allocator);
    defer application.deinit();
    var platform = try create(application.allocator);
    defer platform.deinit();
    application.wakeup = .{ .context = &platform, .schedule = p.Platform.schedule };
    defer application.wakeup = null;
    const focus_handle = application.newFocusHandle();
    var renders: usize = 0;
    const counter = try application.create(Counter{ .platform = platform, .focus = focus_handle, .renders = &renders });
    const root = try application.create(Root{ .child = counter });
    const hosted = try ui.NativeWindow.create(&application, platform, root, .{ .title = "zigui cached native dispatch", .size = .{ .width = 200, .height = 100 } });
    defer hosted.destroy();
    _ = try hosted.content.drawIfNeeded();
    try hosted.content.focus(focus_handle);
    _ = try hosted.content.drawIfNeeded();
    try root.update(Root.notify);
    _ = try hosted.content.drawIfNeeded();
    try std.testing.expectEqual(@as(usize, 2), renders);
    try std.testing.expectEqual(@as(usize, 1), hosted.content.inspect().?.cache_hits);
    const native = MacWindow.cast(hosted.surface.ptr);
    const event = objc.getClass("NSEvent").?.msgSend(objc.Object, "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(usize, 10), bridge.Point{ .x = 0, .y = 0 }, @as(usize, 0), @as(f64, 0), native.window.msgSend(isize, "windowNumber", .{}), @as(c.id, null), bridge.string(" "), bridge.string(" "), false, @as(u16, 49),
    });
    MacPlatform.cast(platform.ptr).application.msgSend(void, "postEvent:atStart:", .{ event, true });
    platform.run();
    try std.testing.expect(hosted.last_error == null);
    try std.testing.expectEqual(@as(u32, 2), (try counter.read()).value);
    _ = try hosted.content.drawIfNeeded();
    try std.testing.expectEqual(@as(usize, 3), renders);
}

test "native windows isolate input, resize, render and survive independent close" {
    const t = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const platform = try create(t.allocator);
    defer platform.deinit();
    const first = try platform.openWindow(.{ .title = "zigui integration A", .size = .{ .width = 160, .height = 120 } });
    defer first.deinit();
    const second = try platform.openWindow(.{ .title = "zigui integration B", .size = .{ .width = 180, .height = 140 } });
    defer second.deinit();
    const Capture = struct {
        platform: p.Platform,
        keys: usize = 0,
        frames: usize = 0,
        resizes: usize = 0,
        texts: usize = 0,
        clicks: usize = 0,
        closed: bool = false,
        fn frame(ptr: *anyopaque, _: p.RequestFrameOptions) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.frames += 1;
        }
        fn resize(ptr: *anyopaque, _: p.Metrics) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.resizes += 1;
        }
        fn event(ptr: *anyopaque, e: input.PlatformInput) input.DispatchEventResult {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (e) {
                .mouse_down => |m| {
                    std.debug.assert(m.position.x == 25 and m.position.y == 30);
                    std.debug.assert(m.button == .left and m.click_count == 2 and m.modifiers.shift);
                    self.clicks += 1;
                },
                .key_down => |k| {
                    std.debug.assert(k.key_code == 0 and std.mem.eql(u8, k.key, "a") and k.is_repeat);
                    self.keys += 1;
                    self.platform.quit();
                },
                .text => |text| {
                    std.debug.assert(std.mem.eql(u8, text.text, "é🐳"));
                    std.debug.assert(text.replacement.?.location == 2);
                    self.texts += 1;
                },
                else => {},
            }
            return .{ .handled = true };
        }
        fn closeWindow(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.closed = true;
        }
        fn callbacks(self: *@This()) p.WindowCallbacks {
            return .{ .context = self, .request_frame = frame, .resize = resize, .input = event, .close = closeWindow };
        }
    };
    var a = Capture{ .platform = platform };
    var b = Capture{ .platform = platform };
    first.setCallbacks(a.callbacks());
    second.setCallbacks(b.callbacks());
    defer first.setCallbacks(null);
    defer second.setCallbacks(null);
    const wa = MacWindow.cast(first.ptr);
    const wb = MacWindow.cast(second.ptr);
    try t.expect(wa.renderer.layer.value != wb.renderer.layer.value);
    wa.window.msgSend(void, "setContentSize:", .{bridge.Size{ .width = 240, .height = 160 }});
    wa.syncMetrics();
    try t.expectEqual(@as(f32, 240), first.metrics().size.width);
    try t.expectEqual(@as(f32, 180), second.metrics().size.width);
    try t.expect(a.resizes > 0);
    var scene: @import("../scene.zig").Scene = .{};
    defer scene.deinit(t.allocator);
    try scene.quad(t.allocator, .{ .bounds = .{ .size = .{ .width = 100, .height = 100 } }, .clip = .{ .origin = .{ .x = 20, .y = 20 }, .size = .{ .width = 40, .height = 40 } }, .color = .{ .r = 1, .a = 0.5 } });
    try first.draw(&scene);
    try second.draw(&scene);
    try wa.renderer.resize(first.metrics().size, 2);
    try t.expectEqual(@as(f64, 480), wa.renderer.layer.msgSend(bridge.Size, "drawableSize", .{}).width);
    try first.draw(&scene);
    try wa.renderer.resize(first.metrics().size, first.metrics().scale);
    const click_location = wa.view.msgSend(bridge.Point, "convertPoint:toView:", .{ bridge.Point{ .x = 25, .y = 30 }, @as(c.id, null) });
    const click = objc.getClass("NSEvent").?.msgSend(objc.Object, "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
        @as(usize, 1), click_location, @as(usize, 1 << 17), @as(f64, 0), wa.window.msgSend(isize, "windowNumber", .{}), @as(c.id, null), @as(isize, 1), @as(isize, 2), @as(f32, 1),
    });
    wa.view.msgSend(void, "mouseDown:", .{click});
    try t.expectEqual(@as(usize, 1), a.clicks);
    try t.expectEqual(@as(usize, 0), b.clicks);
    wa.view.msgSend(void, "setMarkedText:selectedRange:replacementRange:", .{ bridge.string("é"), Range{ .location = 1, .length = 0 }, Range{ .location = not_found, .length = 0 } });
    try t.expect(wa.view.msgSend(bool, "hasMarkedText", .{}));
    wa.view.msgSend(void, "insertText:replacementRange:", .{ bridge.string("é🐳"), Range{ .location = 2, .length = 1 } });
    try t.expect(!wa.view.msgSend(bool, "hasMarkedText", .{}));
    try t.expectEqual(@as(usize, 1), a.texts);
    try t.expectEqual(@as(usize, 0), b.texts);
    wa.window.msgSend(void, "close", .{});
    try t.expect(a.closed);
    try t.expect(!b.closed);
    try t.expectError(error.SurfaceUnavailable, first.draw(&scene));
    try second.draw(&scene);
    const event = objc.getClass("NSEvent").?.msgSend(objc.Object, "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(usize, 10), bridge.Point{ .x = 0, .y = 0 }, @as(usize, 0), @as(f64, 0), wb.window.msgSend(isize, "windowNumber", .{}), @as(c.id, null), bridge.string("a"), bridge.string("a"), true, @as(u16, 0),
    });
    MacPlatform.cast(platform.ptr).application.msgSend(void, "postEvent:atStart:", .{ event, true });
    platform.run();
    try t.expectEqual(@as(usize, 0), a.keys);
    try t.expectEqual(@as(usize, 1), b.keys);
    try t.expect(b.frames > 0);
}

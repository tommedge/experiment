// Example-local adaptation of ../editor/src/main.zig's dispatch_async_f wakeup.
const std = @import("std");
const objc = @import("objc");
extern var _dispatch_main_q: anyopaque;
extern fn dispatch_async_f(?*anyopaque, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern var kCFRunLoopDefaultMode: ?*anyopaque;
extern fn CFRunLoopRunInMode(?*anyopaque, f64, bool) c_int;

/// Thread-safe scheduling bridge with a stable address. The producer is joined
/// before detachAndDrain, ensuring queued callbacks cannot outlive their context.
pub const WakeBridge = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque) void,
    active: bool = true,
    pending: std.atomic.Value(usize) = .init(0),
    pub fn notify(ptr: *anyopaque) callconv(.c) void {
        const self: *WakeBridge = @ptrCast(@alignCast(ptr));
        _ = self.pending.fetchAdd(1, .acq_rel);
        dispatch_async_f(@ptrCast(&_dispatch_main_q), self, onMain);
    }
    fn onMain(ptr: ?*anyopaque) callconv(.c) void {
        const self: *WakeBridge = @ptrCast(@alignCast(ptr.?));
        defer _ = self.pending.fetchSub(1, .acq_rel);
        if (self.active) self.deliver(self.context);
    }
    pub fn detachAndDrain(self: *WakeBridge) void {
        self.active = false;
        while (self.pending.load(.acquire) != 0) _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    }
};

/// Copies a user-requested paste from the system clipboard into owned UTF-8.
pub fn clipboard(a: std.mem.Allocator) !?[]u8 {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const board = objc.getClass("NSPasteboard").?.msgSend(objc.Object, "generalPasteboard", .{});
    const kind = objc.getClass("NSString").?.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*:0]const u8, "public.utf8-plain-text")});
    const value = board.msgSend(objc.Object, "stringForType:", .{kind});
    if (value.value == null) return null;
    const bytes = value.msgSend(?[*]const u8, "UTF8String", .{}) orelse return null;
    const length = value.msgSend(usize, "lengthOfBytesUsingEncoding:", .{@as(usize, 4)});
    return try a.dupe(u8, bytes[0..length]);
}

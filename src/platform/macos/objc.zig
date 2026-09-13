pub const objc = @import("objc");
pub const c = objc.c;
pub const Point = extern struct { x: f64, y: f64 };
pub const Size = extern struct { width: f64, height: f64 };
pub const Rect = extern struct { origin: Point = .{ .x = 0, .y = 0 }, size: Size };
pub fn object(id: c.id) objc.Object {
    return .{ .value = id };
}
pub fn string(bytes: []const u8) objc.Object {
    return objc.getClass("NSString").?.msgSend(objc.Object, "stringWithBytes:length:encoding:", .{ bytes.ptr, bytes.len, @as(usize, 4) });
}
pub fn new(comptime name: [:0]const u8) objc.Object {
    return objc.getClass(name).?.msgSend(objc.Object, "new", .{});
}
pub fn checked(value: objc.Object) !objc.Object {
    if (value.value == null) return error.NativeResourceUnavailable;
    return value;
}

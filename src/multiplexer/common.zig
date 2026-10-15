const std = @import("std");
const p = @import("protocol.zig");
pub const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("time.h");
    @cInclude("arpa/inet.h");
});

var interrupted: c_int = 0;
fn signal(_: c_int) callconv(.c) void {
    const flag: *volatile c_int = &interrupted;
    flag.* = 1;
}
pub fn signals() void {
    interrupted = 0;
    _ = c.signal(c.SIGINT, signal);
    _ = c.signal(c.SIGTERM, signal);
    std.posix.sigaction(.PIPE, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
}
pub fn stopping() bool {
    const flag: *volatile c_int = &interrupted;
    return flag.* != 0;
}
pub fn now() i64 {
    var t: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1_000_000_000 + t.tv_nsec;
}

pub const Address = struct {
    host: []const u8,
    port: u16,
    pub fn parse(bytes: []const u8) !Address {
        const colon = std.mem.lastIndexOfScalar(u8, bytes, ':') orelse return error.InvalidAddress;
        var host = bytes[0..colon];
        if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
        _ = try std.Io.net.IpAddress.parse(host, 0);
        return .{ .host = host, .port = try std.fmt.parseInt(u16, bytes[colon + 1 ..], 10) };
    }
};

/// Retains partial frames across QUIC callbacks. Peeked data is borrowed until
/// consume/append; no partial prefix or payload is ever lost on a tick.
pub const Frames = struct {
    bytes: std.ArrayList(u8) = .empty,
    pub fn deinit(self: *Frames, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
    }
    pub fn append(self: *Frames, a: std.mem.Allocator, bytes: []const u8) !void {
        if (self.bytes.items.len + bytes.len > p.MAX_MESSAGE + 65536) return error.ReceiveQueueFull;
        try self.bytes.appendSlice(a, bytes);
    }
    pub fn peek(self: *Frames) !?[]const u8 {
        const b = self.bytes.items;
        if (b.len < 4) return null;
        const n = std.mem.readInt(u32, b[0..4], .big);
        if (n > p.MAX_MESSAGE) return error.MessageTooLarge;
        if (b.len - 4 < n) return null;
        return b[4 .. 4 + n];
    }
    pub fn consume(self: *Frames, n: usize) void {
        const b = self.bytes.items;
        std.mem.copyForwards(u8, b[0 .. b.len - n - 4], b[n + 4 ..]);
        self.bytes.shrinkRetainingCapacity(b.len - n - 4);
    }
};

test "fragmented and coalesced reliable frames" {
    const a = std.testing.allocator;
    var f: Frames = .{};
    defer f.deinit(a);
    try f.append(a, &.{ 0, 0 });
    try std.testing.expect(try f.peek() == null);
    try f.append(a, &.{ 0, 2, 3 });
    try std.testing.expect(try f.peek() == null);
    try f.append(a, &.{ 4, 0, 0, 0, 1, 9 });
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, (try f.peek()).?);
    f.consume(2);
    try std.testing.expectEqualSlices(u8, &.{9}, (try f.peek()).?);
    f.consume(1);
    try f.append(a, &.{ 0xff, 0, 0, 0 });
    try std.testing.expectError(error.MessageTooLarge, f.peek());
}

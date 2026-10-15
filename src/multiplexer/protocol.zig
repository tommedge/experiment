const std = @import("std");
pub const VERSION: u16 = 3;
pub const MAX_MESSAGE: usize = 4 * 1024 * 1024;

pub const Size = struct {
    cols: u16,
    rows: u16,
    pub fn validate(self: Size) !void {
        if (self.cols == 0 or self.cols > 300 or self.rows == 0 or self.rows > 150) return error.InvalidSize;
    }
};
pub const Cell = struct { text: []const u8, width: u8, fg: [3]u8, bg: [3]u8, attributes: u16, underline: u8 };
pub const Cursor = struct { x: u16, y: u16 };
pub const ChangedRow = struct { y: u16, cells: []Cell };
pub const Update = struct {
    base: u64,
    revision: u64,
    epoch: u64,
    rows: []ChangedRow,
    cursor: ?Cursor,
    application_cursor: bool,
    bracketed_paste: bool,
    alternate_screen: bool,
    exited: bool,
};
pub const Screen = struct {
    revision: u64,
    epoch: u64,
    size: Size,
    rows: [][]Cell,
    cursor: ?Cursor,
    application_cursor: bool,
    bracketed_paste: bool,
    alternate_screen: bool,
    exited: bool,

    pub fn validate(self: Screen) !void {
        try self.size.validate();
        if (self.rows.len != self.size.rows) return error.InvalidDimensions;
        for (self.rows) |row| if (row.len != self.size.cols) return error.InvalidDimensions;
    }

    pub fn text(self: Screen, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.rows, 0..) |row, y| {
            if (y != 0) try out.append(allocator, '\n');
            const start = out.items.len;
            for (row) |cell| if (cell.width != 0) {
                try out.appendSlice(allocator, cell.text);
            };
            // Rust str::trim_end uses Unicode White_Space, not just ASCII.
            while (out.items.len > start) {
                var i = out.items.len - 1;
                while (i > start and out.items[i] & 0xc0 == 0x80) : (i -= 1) {}
                const cp = std.unicode.utf8Decode(out.items[i..]) catch return error.InvalidUtf8;
                if (!whiteSpace(cp)) break;
                out.shrinkRetainingCapacity(i);
            }
        }
        return out.toOwnedSlice(allocator);
    }

    /// Allocates changed row arrays; immutable cell text remains borrowed from self.
    pub fn diff(self: Screen, allocator: std.mem.Allocator, base: Screen) !?Update {
        if (self.epoch != base.epoch or self.size.cols != base.size.cols or self.size.rows != base.size.rows) return null;
        var rows: std.ArrayList(ChangedRow) = .empty;
        errdefer {
            for (rows.items) |row| allocator.free(row.cells);
            rows.deinit(allocator);
        }
        const n = @min(self.rows.len, base.rows.len);
        for (self.rows[0..n], base.rows[0..n], 0..) |a, b, y| {
            if (!rowEqual(a, b)) {
                const cells = try allocator.dupe(Cell, a);
                errdefer allocator.free(cells);
                try rows.append(allocator, .{ .y = @intCast(y), .cells = cells });
            }
        }
        return .{ .base = base.revision, .revision = self.revision, .epoch = self.epoch, .rows = try rows.toOwnedSlice(allocator), .cursor = self.cursor, .application_cursor = self.application_cursor, .bracketed_paste = self.bracketed_paste, .alternate_screen = self.alternate_screen, .exited = self.exited };
    }

    pub fn apply(self: *Screen, update: Update) !bool {
        if (update.base != self.revision or update.epoch != self.epoch or update.revision <= self.revision) return false;
        for (update.rows) |row| if (row.y >= self.rows.len or row.cells.len != self.size.cols) return error.InvalidUpdateRow;
        for (update.rows) |row| self.rows[row.y] = row.cells;
        self.revision = update.revision;
        self.cursor = update.cursor;
        self.application_cursor = update.application_cursor;
        self.bracketed_paste = update.bracketed_paste;
        self.alternate_screen = update.alternate_screen;
        self.exited = update.exited;
        return true;
    }
};

fn whiteSpace(cp: u21) bool {
    return switch (cp) {
        9...13, 32, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}
fn rowEqual(a: []const Cell, b: []const Cell) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.text, y.text) or x.width != y.width or !std.mem.eql(u8, &x.fg, &y.fg) or !std.mem.eql(u8, &x.bg, &y.bg) or x.attributes != y.attributes or x.underline != y.underline) return false;
    }
    return true;
}

pub const Request = union(enum) { list: void, create: Size, attach: struct { id: u64, size: Size } };
pub const Hello = struct { version: u16, token: []const u8, request: Request };
pub const ClientMessage = union(enum) { input: []const u8, resize: Size, ack: u64, detach: void, scroll: struct { request: u64, epoch: u64, lines: i32 } };
pub const TailscaleIdentity = struct { login_name: []const u8, user_id: u64, node_id: []const u8 };
pub const SessionInfo = struct { id: u64, creator: ?TailscaleIdentity };
pub const ServerMessage = union(enum) { sessions: []SessionInfo, attached: u64, snapshot: Screen, err: []const u8, detached: void, scrollback: struct { request: u64, offset: u32, screen: Screen } };

/// Raw Postcard payload. Slices returned by decode belong to the supplied allocator.
pub fn encode(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try write(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}
pub fn frame(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const payload = try encode(allocator, value);
    defer allocator.free(payload);
    const result = try allocator.alloc(u8, payload.len + 4);
    std.mem.writeInt(u32, result[0..4], @intCast(payload.len), .big);
    @memcpy(result[4..], payload);
    return result;
}
fn byte(a: std.mem.Allocator, out: *std.ArrayList(u8), b: u8) !void {
    if (out.items.len >= MAX_MESSAGE) return error.MessageTooLarge;
    try out.append(a, b);
}
fn varint(a: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var v = value;
    while (v >= 128) : (v >>= 7) try byte(a, out, @as(u8, @truncate(v)) | 128);
    try byte(a, out, @intCast(v));
}
fn write(a: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) anyerror!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try byte(a, out, @intFromBool(value)),
        .int => |info| {
            if (T == u8) return byte(a, out, value);
            if (info.signedness == .signed) {
                const U = std.meta.Int(.unsigned, info.bits);
                const bits: U = @bitCast(value);
                try varint(a, out, (bits << 1) ^ @as(U, @bitCast(value >> (info.bits - 1))));
            } else try varint(a, out, value);
        },
        .array => for (value) |v| try write(a, out, v),
        .pointer => |p| {
            if (p.size != .slice) @compileError("only slices supported");
            try varint(a, out, value.len);
            for (value) |v| try write(a, out, v);
        },
        .optional => {
            try byte(a, out, @intFromBool(value != null));
            if (value) |v| try write(a, out, v);
        },
        .@"struct" => |s| inline for (s.fields) |f| try write(a, out, @field(value, f.name)),
        .@"union" => |u| {
            const tag = std.meta.activeTag(value);
            inline for (u.fields, 0..) |f, i| if (tag == @field(std.meta.Tag(T), f.name)) {
                try varint(a, out, i);
                try write(a, out, @field(value, f.name));
            };
        },
        else => @compileError("unsupported Postcard type"),
    }
}

/// Use an arena: partial allocations on decoding errors are reclaimed with it.
/// Decoding checks wire validity; Size/Screen.validate checks semantic dimensions.
pub fn decode(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    if (bytes.len > MAX_MESSAGE) return error.MessageTooLarge;
    var reader = Reader{ .bytes = bytes, .allocator = allocator };
    const result = try reader.read(T);
    if (reader.pos != bytes.len) return error.TrailingBytes;
    return result;
}
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,
    fn take(self: *Reader) !u8 {
        if (self.pos == self.bytes.len) return error.Truncated;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }
    fn integer(self: *Reader, comptime U: type) !U {
        var value: U = 0;
        const bits = @typeInfo(U).int.bits;
        for (0..(bits + 6) / 7) |i| {
            const b = try self.take();
            const shift = i * 7;
            if (@as(u64, b & 127) > (@as(u64, std.math.maxInt(U)) >> @intCast(shift))) return error.InvalidVarint;
            value |= @as(U, @intCast(b & 127)) << @intCast(shift);
            if (b & 128 == 0) return value;
        }
        return error.InvalidVarint;
    }
    fn read(self: *Reader, comptime T: type) anyerror!T {
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => return switch (try self.take()) {
                0 => false,
                1 => true,
                else => error.InvalidBool,
            },
            .int => |info| {
                if (T == u8) return self.take();
                const U = std.meta.Int(.unsigned, info.bits);
                const v = try self.integer(U);
                if (info.signedness == .unsigned) return v;
                return @bitCast((v >> 1) ^ (0 -% (v & 1)));
            },
            .array => |ar| {
                var result: T = undefined;
                for (&result) |*v| v.* = try self.read(ar.child);
                return result;
            },
            .pointer => |p| {
                if (p.size != .slice) @compileError("only slices supported");
                const len = try self.integer(usize);
                // Every supported sequence element consumes at least one wire byte.
                if (len > self.bytes.len - self.pos) return error.Truncated;
                const result = try self.allocator.alloc(p.child, len);
                for (result) |*v| v.* = try self.read(p.child);
                return result;
            },
            .optional => |o| return switch (try self.take()) {
                0 => null,
                1 => try self.read(o.child),
                else => error.InvalidOption,
            },
            .@"struct" => |s| {
                var result: T = undefined;
                inline for (s.fields) |f| {
                    @field(result, f.name) = try self.read(f.type);
                    if (comptime std.mem.eql(u8, f.name, "text") or std.mem.eql(u8, f.name, "login_name") or std.mem.eql(u8, f.name, "node_id")) {
                        if (!std.unicode.utf8ValidateSlice(@field(result, f.name))) return error.InvalidUtf8;
                    }
                }
                return result;
            },
            .@"union" => |u| {
                const tag = try self.integer(u32);
                inline for (u.fields, 0..) |f, i| if (tag == i) {
                    const v = try self.read(f.type);
                    if (comptime T == ServerMessage and std.mem.eql(u8, f.name, "err")) {
                        if (!std.unicode.utf8ValidateSlice(v)) return error.InvalidUtf8;
                    }
                    return @unionInit(T, f.name, v);
                };
                return error.InvalidTag;
            },
            else => @compileError("unsupported Postcard type"),
        }
    }
};

fn fixture(value: anytype, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualSlices(u8, expected, try encode(a, value));
    const decoded = try decode(@TypeOf(value), a, expected);
    try std.testing.expectEqualSlices(u8, expected, try encode(a, decoded));
    const framed = try frame(a, value);
    try std.testing.expectEqual(expected.len, std.mem.readInt(u32, framed[0..4], .big));
    try std.testing.expectEqualSlices(u8, expected, framed[4..]);
}

test "v3 hand-derived Postcard fixtures and signed ZigZag boundaries" {
    try fixture(Hello{ .version = VERSION, .token = &.{ 255, 0 }, .request = .{ .attach = .{ .id = 128, .size = .{ .cols = 300, .rows = 150 } } } }, &.{ 3, 2, 255, 0, 2, 128, 1, 172, 2, 150, 1 });
    try fixture(Request{ .list = {} }, &.{0});
    try fixture(Request{ .create = .{ .cols = 1, .rows = 2 } }, &.{ 1, 1, 2 });
    try fixture(ClientMessage{ .scroll = .{ .request = 1, .epoch = 128, .lines = -65 } }, &.{ 4, 1, 128, 1, 129, 1 });
    try fixture(@as(i32, std.math.minInt(i32)), &.{ 255, 255, 255, 255, 15 });
    try fixture(@as(i32, std.math.maxInt(i32)), &.{ 254, 255, 255, 255, 15 });
    try fixture(@as(i32, -1), &.{1});
    try fixture(@as(i32, 64), &.{ 128, 1 });
    try fixture(@as(u64, std.math.maxInt(u64)), &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 1 });
    try fixture(ServerMessage{ .sessions = @constCast(&[_]SessionInfo{.{ .id = 7, .creator = .{ .login_name = "a", .user_id = 128, .node_id = "n" } }}) }, &.{ 0, 1, 7, 1, 1, 'a', 128, 1, 1, 'n' });
    try fixture(ServerMessage{ .err = "界" }, &.{ 3, 3, 0xe7, 0x95, 0x8c });
    try fixture(ClientMessage{ .input = &.{255} }, &.{ 0, 1, 255 });
    try fixture(ClientMessage{ .resize = .{ .cols = 1, .rows = 1 } }, &.{ 1, 1, 1 });
    try fixture(ClientMessage{ .ack = 128 }, &.{ 2, 128, 1 });
    try fixture(ClientMessage{ .detach = {} }, &.{3});
    try fixture(ServerMessage{ .attached = 1 }, &.{ 1, 1 });
    try fixture(ServerMessage{ .detached = {} }, &.{4});
    try fixture(Cursor{ .x = 128, .y = 1 }, &.{ 128, 1, 1 });
    try fixture(Cell{ .text = "a", .width = 1, .fg = .{ 128, 255, 0 }, .bg = .{ 1, 2, 3 }, .attributes = 128, .underline = 2 }, &.{ 1, 'a', 1, 128, 255, 0, 1, 2, 3, 128, 1, 2 });
}

test "strict malformed and truncated decoding, size and cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.Truncated, decode(u16, a, &.{128}));
    try std.testing.expectError(error.InvalidVarint, decode(u16, a, &.{ 255, 255, 4 }));
    try std.testing.expectError(error.InvalidVarint, decode(u64, a, &.{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 2 }));
    try std.testing.expectError(error.InvalidBool, decode(bool, a, &.{2}));
    try std.testing.expectError(error.InvalidOption, decode(?Cursor, a, &.{2}));
    try std.testing.expectError(error.InvalidTag, decode(Request, a, &.{3}));
    try std.testing.expectError(error.TrailingBytes, decode(Request, a, &.{ 0, 0 }));
    try std.testing.expectError(error.Truncated, decode(ClientMessage, a, &.{ 0, 2, 1 }));
    try std.testing.expectError(error.InvalidUtf8, decode(ServerMessage, a, &.{ 3, 1, 255 }));
    try std.testing.expectError(error.InvalidSize, (Size{ .cols = 0, .rows = 1 }).validate());
    try (Size{ .cols = 300, .rows = 150 }).validate();
    const huge = try a.alloc(u8, MAX_MESSAGE + 1);
    @memset(huge, 0);
    try std.testing.expectError(error.MessageTooLarge, decode(Hello, a, huge));
    try std.testing.expectError(error.MessageTooLarge, frame(a, ClientMessage{ .input = huge }));
    // One tag byte + four length bytes + data exactly fills the cap.
    const at_cap = try frame(a, ClientMessage{ .input = huge[0 .. MAX_MESSAGE - 5] });
    try std.testing.expectEqual(@as(usize, MAX_MESSAGE + 4), at_cap.len);
    try std.testing.expectEqual(@as(u32, MAX_MESSAGE), std.mem.readInt(u32, at_cap[0..4], .big));
    _ = try decode(ClientMessage, a, at_cap[4..]);
    const valid = try encode(a, Hello{ .version = 3, .token = "abc", .request = .{ .attach = .{ .id = 999, .size = .{ .cols = 300, .rows = 150 } } } });
    for (0..valid.len) |n| try std.testing.expectError(error.Truncated, decode(Hello, a, valid[0..n]));
}

test "Screen diff apply cumulative recovery, stale rejection, atomic validation and Unicode text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blank = Cell{ .text = " ", .width = 1, .fg = .{ 0, 0, 0 }, .bg = .{ 0, 0, 0 }, .attributes = 0, .underline = 0 };
    var old = [_]Cell{ blank, blank, blank, blank };
    var fresh = old;
    fresh[0].text = "界";
    fresh[0].width = 2;
    fresh[1].width = 0;
    fresh[1].text = "ignored";
    fresh[2].text = "e\u{301}";
    fresh[3].text = "\u{3000}";
    var old_rows = [_][]Cell{ &old, &old };
    var fresh_rows = [_][]Cell{ &fresh, &old };
    var first = Screen{ .revision = 1, .epoch = 7, .size = .{ .cols = 4, .rows = 2 }, .rows = &old_rows, .cursor = null, .application_cursor = false, .bracketed_paste = false, .alternate_screen = false, .exited = false };
    var third = first;
    third.rows = &fresh_rows;
    third.revision = 3;
    third.cursor = .{ .x = 2, .y = 1 };
    try first.validate();
    try fixture(ServerMessage{ .snapshot = first }, &.{ 2, 1, 7, 4, 2, 2, 4, 1, 32, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 32, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 32, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 32, 1, 0, 0, 0, 0, 0, 0, 0, 0, 4, 1, 32, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 32, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 32, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 32, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    const update = (try third.diff(a, first)).?;
    try std.testing.expectEqual(@as(usize, 1), update.rows.len);
    var tiny = first;
    tiny.size = .{ .cols = 1, .rows = 1 };
    var tiny_cells = [_]Cell{blank};
    var tiny_rows = [_][]Cell{&tiny_cells};
    tiny.rows = &tiny_rows;
    try fixture(ServerMessage{ .scrollback = .{ .request = 128, .offset = 128, .screen = tiny } }, &.{ 5, 128, 1, 128, 1, 1, 7, 1, 1, 1, 1, 1, 32, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    try fixture(Update{ .base = 1, .revision = 3, .epoch = 7, .rows = @constCast(&[_]ChangedRow{.{ .y = 128, .cells = &tiny_cells }}), .cursor = .{ .x = 1, .y = 2 }, .application_cursor = true, .bracketed_paste = false, .alternate_screen = true, .exited = false }, &.{ 1, 3, 7, 1, 128, 1, 1, 1, 32, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 1, 0, 1, 0 });
    const wire = try encode(a, update);
    const received = try decode(Update, a, wire);
    var bad = update;
    bad.rows = try a.dupe(ChangedRow, &.{ update.rows[0], .{ .y = 99, .cells = &fresh } });
    try std.testing.expectError(error.InvalidUpdateRow, first.apply(bad));
    try std.testing.expectEqual(@as(u64, 1), first.revision);
    try std.testing.expect(rowEqual(first.rows[0], &old));
    bad.rows[1].y = 1;
    bad.rows[1].cells = fresh[0..1];
    try std.testing.expectError(error.InvalidUpdateRow, first.apply(bad));
    try std.testing.expect(rowEqual(first.rows[0], &old));
    bad.base = 2;
    try std.testing.expect(!try first.apply(bad));
    bad = update;
    bad.epoch += 1;
    try std.testing.expect(!try first.apply(bad));
    try std.testing.expect(try first.apply(received));
    try std.testing.expectEqualStrings("界e\u{301}\n", try first.text(a));
    try std.testing.expect(!try first.apply(received));
    third.epoch += 1;
    try std.testing.expect((try third.diff(a, first)) == null);
    third.epoch = first.epoch;
    third.size.cols += 1;
    try std.testing.expect((try third.diff(a, first)) == null);
    try std.testing.expectError(error.InvalidDimensions, third.validate());
}

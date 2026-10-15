const std = @import("std");
const p = @import("protocol.zig");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("errno.h");
});

/// Handles partial writes and limits consecutive EINTR retries.
pub fn write(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    var interrupted: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0) {
            if (std.c._errno().* == c.EINTR and interrupted < 64) {
                interrupted += 1;
                continue;
            }
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        interrupted = 0;
        offset += @intCast(n);
    }
}

const reset = "\x1b[0m\x1b[?25h\x1b[?7h\x1b[?2004l\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?1049l";
pub const Guard = struct {
    original: c.struct_termios,
    active: bool = true,

    pub fn enter() !Guard {
        var guard: Guard = undefined;
        if (c.tcgetattr(0, &guard.original) != 0) return error.TermiosFailed;
        guard.active = true;
        var raw = guard.original;
        c.cfmakeraw(&raw);
        // Even a failed setup may have changed terminal state.
        errdefer guard.leave();
        if (c.tcsetattr(0, c.TCSANOW, &raw) != 0) return error.TermiosFailed;
        try write(1, "\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?7l\x1b[?2004h");
        return guard;
    }

    pub fn leave(self: *Guard) void {
        if (!self.active) return;
        self.active = false;
        write(1, reset) catch {};
        var retries: usize = 0;
        while (c.tcsetattr(0, c.TCSANOW, &self.original) != 0) {
            if (std.c._errno().* != c.EINTR or retries == 64) break;
            retries += 1;
        }
    }
};

pub fn size() !p.Size {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(1, c.TIOCGWINSZ, &ws) != 0) return error.SizeFailed;
    return .{ .cols = ws.ws_col, .rows = ws.ws_row };
}

fn format(a: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const bytes = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(bytes);
    try out.appendSlice(a, bytes);
}

fn sameStyle(a: p.Cell, b: p.Cell) bool {
    return std.mem.eql(u8, &a.fg, &b.fg) and std.mem.eql(u8, &a.bg, &b.bg) and a.attributes == b.attributes and a.underline == b.underline;
}
fn sameRow(a: []const p.Cell, b: []const p.Cell) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!sameStyle(x, y) or x.width != y.width or !std.mem.eql(u8, x.text, y.text)) return false;
    return true;
}

/// Text is UTF-8 decoded before filtering, so encoded C1 controls cannot escape.
pub fn draw(allocator: Allocator, screen: p.Screen, previous: ?p.Screen) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const full = if (previous) |old| old.epoch != screen.epoch or old.size.cols != screen.size.cols or old.size.rows != screen.size.rows else true;
    try out.appendSlice(allocator, "\x1b[?25l");
    if (full) try out.appendSlice(allocator, "\x1b[0m\x1b[2J");
    var style: ?p.Cell = null;
    for (screen.rows, 0..) |row, y| {
        if (!full) if (previous) |old| {
            if (y < old.rows.len and sameRow(row, old.rows[y])) continue;
        };
        var next_x: ?usize = null;
        for (row, 0..) |cell, x| {
            if (cell.width == 0) continue;
            if (next_x == null or next_x.? != x) try format(allocator, &out, "\x1b[{d};{d}H", .{ y + 1, x + 1 });
            if (style == null or !sameStyle(style.?, cell)) {
                try format(allocator, &out, "\x1b[0;38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{ cell.fg[0], cell.fg[1], cell.fg[2], cell.bg[0], cell.bg[1], cell.bg[2] });
                for ([_]u8{ 1, 3, 2, 5, 7, 8, 9, 53 }, 0..) |sgr, bit| {
                    if (cell.attributes & (@as(u16, 1) << @intCast(bit)) != 0) try format(allocator, &out, "\x1b[{d}m", .{sgr});
                }
                if (cell.underline != 0) try format(allocator, &out, "\x1b[4:{d}m", .{cell.underline});
                style = cell;
            }
            var clean = cell.text.len != 0;
            var i: usize = 0;
            while (i < cell.text.len) {
                const n = std.unicode.utf8ByteSequenceLength(cell.text[i]) catch {
                    clean = false;
                    i += 1;
                    continue;
                };
                if (n > cell.text.len - i) {
                    clean = false;
                    break;
                }
                const cp = std.unicode.utf8Decode(cell.text[i..][0..n]) catch {
                    clean = false;
                    i += 1;
                    continue;
                };
                if (cp < 32 or (cp >= 127 and cp <= 159)) {
                    clean = false;
                } else try out.appendSlice(allocator, cell.text[i..][0..n]);
                i += n;
            }
            next_x = if (clean) x + cell.width else null;
        }
    }
    try out.appendSlice(allocator, "\x1b[0m");
    if (screen.cursor) |cursor| try format(allocator, &out, "\x1b[{d};{d}H\x1b[?25h", .{ @as(usize, cursor.y) + 1, @as(usize, cursor.x) + 1 });
    return out.toOwnedSlice(allocator);
}

pub const Action = union(enum) { input: []const u8, scroll: i32, detach: void, live: void };
fn consume(buffer: *std.ArrayList(u8), n: usize) void {
    std.mem.copyForwards(u8, buffer.items[0 .. buffer.items.len - n], buffer.items[n..]);
    buffer.shrinkRetainingCapacity(buffer.items.len - n);
}
fn input(a: Allocator, buffer: *std.ArrayList(u8), n: usize, bytes: []const u8) !?Action {
    const owned = try a.dupe(u8, bytes);
    consume(buffer, n);
    return .{ .input = owned };
}

/// Incomplete actions leave the buffer untouched. Ignored mouse events emit an
/// owned empty input action, allowing callers to keep draining queued events.
/// A lone ESC is deliberately left for the caller's timeout/live-view policy.
pub fn next(allocator: Allocator, buffer: *std.ArrayList(u8), application_cursor: bool, bracketed_paste: bool, page: i32) !?Action {
    const b = buffer.items;
    if (b.len == 0) return null;
    if (b[0] == 0x1d) {
        consume(buffer, 1);
        return .detach;
    }
    if (b[0] != 27) {
        const n = std.unicode.utf8ByteSequenceLength(b[0]) catch 1;
        if (b.len < n) return null;
        return input(allocator, buffer, n, b[0..n]);
    }
    if (b.len == 1) return null;
    if (std.mem.startsWith(u8, b, "\x1b[200~")) {
        const end = std.mem.indexOf(u8, b[6..], "\x1b[201~") orelse return null;
        const n = 6 + end + 6;
        return input(allocator, buffer, n, if (bracketed_paste) b[0..n] else b[6 .. 6 + end]);
    }
    var n: usize = 2;
    if (b[1] == '[' or b[1] == 'O') {
        n = 2;
        while (n < b.len and !(b[n] >= 0x40 and b[n] <= 0x7e)) : (n += 1) {}
        if (n == b.len) return null;
        n += 1;
        // Legacy X10 mouse reports have three bytes after CSI M.
        if (std.mem.eql(u8, b[0..n], "\x1b[M")) {
            if (b.len < n + 3) return null;
            return input(allocator, buffer, n + 3, "");
        }
    } else if (b[1] == ']' or b[1] == 'P' or b[1] == '^' or b[1] == '_' or b[1] == 'X') {
        n = 2;
        while (n < b.len) : (n += 1) {
            if (b[1] == ']' and b[n] == 7) {
                n += 1;
                break;
            }
            if (b[n] == 27 and n + 1 < b.len and b[n + 1] == '\\') {
                n += 2;
                break;
            }
        } else return null;
    } else {
        // ESC intermediates, or an Alt-modified UTF-8 character.
        while (n <= b.len and b[n - 1] >= 0x20 and b[n - 1] <= 0x2f) : (n += 1) {}
        if (n > b.len) return null;
        if (n == 2 and b[1] >= 128) {
            n = 1 + @as(usize, std.unicode.utf8ByteSequenceLength(b[1]) catch 1);
            if (b.len < n) return null;
        }
    }
    const seq = b[0..n];
    if (std.mem.eql(u8, seq, "\x1b[5;2~") or std.mem.eql(u8, seq, "\x1b[6;2~")) {
        const lines = if (seq[2] == '5') page else @as(i32, 0) -| page;
        consume(buffer, n);
        return .{ .scroll = lines };
    }
    if (std.mem.startsWith(u8, seq, "\x1b[<") and (seq[n - 1] == 'M' or seq[n - 1] == 'm')) {
        var fields = std.mem.splitScalar(u8, seq[3 .. n - 1], ';');
        const button = std.fmt.parseInt(u16, fields.next() orelse "", 10) catch 0;
        const x = std.fmt.parseInt(u16, fields.next() orelse "", 10) catch 0;
        const y = std.fmt.parseInt(u16, fields.next() orelse "", 10) catch 0;
        if (x != 0 and y != 0 and fields.next() == null and seq[n - 1] == 'M' and (button == 64 or button == 65)) {
            consume(buffer, n);
            return .{ .scroll = if (button == 64) 3 else -3 };
        }
        return input(allocator, buffer, n, "");
    }
    var code: ?u8 = null;
    if (n == 3 and (b[1] == '[' or b[1] == 'O') and std.mem.indexOfScalar(u8, "ABCDHF", b[2]) != null) code = b[2];
    if (std.mem.eql(u8, seq, "\x1b[1~") or std.mem.eql(u8, seq, "\x1b[7~")) code = 'H';
    if (std.mem.eql(u8, seq, "\x1b[4~") or std.mem.eql(u8, seq, "\x1b[8~")) code = 'F';
    if (code) |key| {
        const mapped = [_]u8{ 27, if (application_cursor) 'O' else '[', key };
        return input(allocator, buffer, n, &mapped);
    }
    return input(allocator, buffer, n, seq);
}

test "draw styled graphemes, filtered controls, wide continuation and row diff" {
    const a = std.testing.allocator;
    const base = p.Cell{ .text = "界", .width = 2, .fg = .{ 1, 2, 3 }, .bg = .{ 4, 5, 6 }, .attributes = 255, .underline = 3 };
    var cells = [_]p.Cell{ base, base, base, base, base };
    cells[1].width = 0;
    cells[1].text = "NEVER";
    cells[2].text = "e\u{301}";
    cells[2].width = 1;
    cells[3].text = "\x1b]52;bad\x07\u{9b}\xff";
    cells[3].width = 1;
    cells[4].text = "Z";
    cells[4].width = 1;
    var rows = [_][]p.Cell{ &cells, &cells };
    var screen = p.Screen{ .revision = 1, .epoch = 1, .size = .{ .cols = 5, .rows = 2 }, .rows = &rows, .cursor = .{ .x = 4, .y = 1 }, .application_cursor = false, .bracketed_paste = false, .alternate_screen = false, .exited = false };
    const out = try draw(a, screen, null);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "界e\u{301}]52;bad\x1b[1;5HZ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NEVER") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]52") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{9b}") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0;38;2;1;2;3;48;2;4;5;6m\x1b[1m\x1b[3m\x1b[2m\x1b[5m\x1b[7m\x1b[8m\x1b[9m\x1b[53m\x1b[4:3m") != null);
    const unchanged = try draw(a, screen, screen);
    defer a.free(unchanged);
    try std.testing.expectEqualStrings("\x1b[?25l\x1b[0m\x1b[2;5H\x1b[?25h", unchanged);
    var changed = cells;
    changed[4].text = "Q";
    var new_rows = [_][]p.Cell{ &cells, &changed };
    const old = screen;
    screen.rows = &new_rows;
    const delta = try draw(a, screen, old);
    defer a.free(delta);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\x1b[1;1H") == null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\x1b[2;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\x1b[2J") == null);
    screen.epoch += 1;
    const repaint = try draw(a, screen, old);
    defer a.free(repaint);
    try std.testing.expect(std.mem.indexOf(u8, repaint, "\x1b[2J") != null);
}

fn checkInput(bytes: []const u8, expected: []const u8, app: bool, paste: bool) !void {
    const a = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    // Every strict prefix must remain untouched until the action is complete.
    for (bytes, 0..) |byte, i| {
        try buffer.append(a, byte);
        const action = try next(a, &buffer, app, paste, 23);
        if (i + 1 < bytes.len) {
            try std.testing.expect(action == null);
            try std.testing.expectEqualSlices(u8, bytes[0 .. i + 1], buffer.items);
        } else {
            const result = action.?.input;
            defer a.free(result);
            try std.testing.expectEqualSlices(u8, expected, result);
            try std.testing.expectEqual(@as(usize, 0), buffer.items.len);
        }
    }
}

test "incremental input arrows, home/end, paste, UTF8 and complete escape sequences" {
    try checkInput("\x1b[A", "\x1bOA", true, false);
    try checkInput("\x1bOF", "\x1b[F", false, false);
    try checkInput("\x1b[7~", "\x1bOH", true, false);
    try checkInput("\x1b[3~", "\x1b[3~", true, false);
    try checkInput("\x1b[1;5D", "\x1b[1;5D", true, false);
    try checkInput("\x1b[200~hello\x1d界\x1b[201~", "hello\x1d界", false, false);
    try checkInput("\x1b[200~hello\x1b[201~", "\x1b[200~hello\x1b[201~", false, true);
    try checkInput("界", "界", false, false);
    try checkInput("\x1b界", "\x1b界", false, false);
    try checkInput("\x1b]title\x07", "\x1b]title\x07", false, false);
    try checkInput("\x1bPdata\x1b\\", "\x1bPdata\x1b\\", false, false);
    try checkInput("\x1b(B", "\x1b(B", false, false);
    try checkInput("\x1b[<0;1;2M", "", false, false);
    try checkInput("\x01", "\x01", false, false);
}

test "partial wheel/page actions and ordered control bytes" {
    const a = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    const sequences = [_][]const u8{ "\x1b[<64;12;3M", "\x1b[<65;12;3M", "\x1b[5;2~", "\x1b[6;2~" };
    for (sequences, [_]i32{ 3, -3, 23, -23 }) |seq, lines| {
        for (seq, 0..) |byte, i| {
            try buffer.append(a, byte);
            const result = try next(a, &buffer, false, false, 23);
            if (i + 1 < seq.len) try std.testing.expect(result == null) else try std.testing.expectEqual(lines, result.?.scroll);
        }
    }
    try buffer.appendSlice(a, "a\x1d\r\x1b");
    const first = (try next(a, &buffer, false, false, 23)).?.input;
    defer a.free(first);
    try std.testing.expectEqualStrings("a", first);
    try std.testing.expect((try next(a, &buffer, false, false, 23)).? == .detach);
    const enter = (try next(a, &buffer, false, false, 23)).?.input;
    defer a.free(enter);
    try std.testing.expectEqualStrings("\r", enter);
    try std.testing.expect(try next(a, &buffer, false, false, 23) == null);
    try std.testing.expectEqualStrings("\x1b", buffer.items);
}

test "libc public API compiles and failed writes are reported" {
    std.testing.refAllDecls(Guard);
    _ = &size;
    try std.testing.expectError(error.WriteFailed, write(-1, "x"));
}

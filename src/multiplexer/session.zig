const std = @import("std");
const vt = @import("ghostty-vt");
const p = @import("protocol.zig");
const Allocator = std.mem.Allocator;
const c = @cImport({
    if (@import("builtin").os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
});

extern "c" var environ: [*:null]?[*:0]u8;

/// All methods and Ghostty callbacks must run on the same caller thread.
/// Screen slices remain valid until the next observable update or destroy.
/// Connections must release their anchors before destroying the session.
pub const Session = struct {
    allocator: Allocator,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    arena: std.heap.ArenaAllocator,
    screen: p.Screen,
    fd: c_int,
    child: c.pid_t,
    queue: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    exited: bool = false,
    reply_error: ?anyerror = null,

    pub fn create(allocator: Allocator, io: std.Io, shell: []const u8, size: p.Size) !*Session {
        try size.validate();
        const name = try allocator.dupeZ(u8, shell);
        defer allocator.free(name);
        // Snapshot all exec data before fork: the child must not enter libc's
        // allocator or environment locks held by another std.Io worker.
        var exec_arena = std.heap.ArenaAllocator.init(allocator);
        defer exec_arena.deinit();
        const a = exec_arena.allocator();
        var env: std.ArrayList(?[*:0]const u8) = .empty;
        var path: []const u8 = "/bin:/usr/bin";
        var i: usize = 0;
        while (environ[i]) |entry| : (i += 1) {
            const value = std.mem.span(entry);
            if (std.mem.startsWith(u8, value, "PATH=")) path = try a.dupe(u8, value[5..]);
            if (std.mem.startsWith(u8, value, "TERM=") or
                std.mem.startsWith(u8, value, "PS1=") or
                std.mem.startsWith(u8, value, "PS2=")) continue;
            try env.append(a, (try a.dupeZ(u8, value)).ptr);
        }
        try env.append(a, "TERM=xterm-256color");
        const envp = try env.toOwnedSliceSentinel(a, null);
        const executable = if (std.mem.indexOfScalar(u8, shell, '/') != null) name else blk: {
            var dirs = std.mem.splitScalar(u8, path, ':');
            while (dirs.next()) |dir| {
                const candidate = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, shell }, 0);
                if (c.access(candidate.ptr, c.X_OK) == 0) break :blk candidate;
            }
            return error.ShellNotFound;
        };
        const argv = [_:null]?[*:0]const u8{name.ptr};
        var master: c_int = -1;
        var slave: c_int = -1;
        var ws = winsize(size);
        if (c.openpty(&master, &slave, null, null, &ws) != 0) return error.PtyOpen;
        errdefer _ = c.close(master);
        defer _ = c.close(slave);
        if (c.fcntl(master, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0 or
            c.fcntl(master, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.PtyFlags;
        const pid = c.fork();
        if (pid < 0) return error.Fork;
        if (pid == 0) {
            _ = c.close(master);
            if (c.setsid() < 0 or c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0)) < 0) c._exit(126);
            for (0..3) |fd| if (c.dup2(slave, @intCast(fd)) < 0) c._exit(126);
            if (slave > 2) _ = c.close(slave);
            _ = c.execve(executable.ptr, @ptrCast(&argv), @ptrCast(envp.ptr));
            c._exit(127);
        }
        errdefer reap(pid);
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .terminal = try vt.Terminal.init(io, allocator, .{ .cols = size.cols, .rows = size.rows, .max_scrollback_bytes = 8 * 1024 * 1024, .max_scrollback_lines = 10_000 }),
            .stream = undefined,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .screen = undefined,
            .fd = master,
            .child = pid,
        };
        errdefer self.terminal.deinit(allocator);
        errdefer self.arena.deinit();
        self.stream = self.terminal.vtStream();
        errdefer self.stream.deinit();
        self.stream.handler.effects.write_pty = reply;
        self.screen = try self.capture(self.arena.allocator(), null, 1);
        return self;
    }

    pub fn destroy(self: *Session) void {
        reap(self.child);
        _ = c.close(self.fd);
        self.stream.deinit();
        self.terminal.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn reply(handler: *vt.TerminalStream.Handler, bytes: []const u8) void {
        const self: *Session = @fieldParentPtr("terminal", handler.terminal);
        self.input(bytes) catch |err| {
            self.reply_error = err;
        };
    }

    pub fn input(self: *Session, bytes: []const u8) !void {
        if (bytes.len > 65536) return error.InputTooLarge;
        if (self.exited) return error.SessionExited;
        if (self.queue.items.len - self.sent + bytes.len > 1024 * 1024) return error.InputQueueFull;
        if (self.sent != 0) {
            const remaining = self.queue.items.len - self.sent;
            std.mem.copyForwards(u8, self.queue.items[0..remaining], self.queue.items[self.sent..]);
            self.queue.shrinkRetainingCapacity(remaining);
            self.sent = 0;
        }
        try self.queue.appendSlice(self.allocator, bytes);
    }

    fn flush(self: *Session) !void {
        var budget: usize = 65536;
        while (!self.exited and self.sent < self.queue.items.len and budget > 0) {
            const bytes = self.queue.items[self.sent..][0..@min(budget, self.queue.items.len - self.sent)];
            const n = c.write(self.fd, bytes.ptr, bytes.len);
            if (n < 0) {
                const e = std.posix.errno(n);
                if (e == .AGAIN or e == .INTR) break;
                if (e == .IO or e == .PIPE) {
                    self.exited = true;
                    break;
                }
                return error.PtyWrite;
            }
            if (n == 0) break;
            self.sent += @intCast(n);
            budget -= @intCast(n);
        }
        if (self.sent == self.queue.items.len or self.exited) {
            self.queue.clearRetainingCapacity();
            self.sent = 0;
        }
    }

    /// Returns whether the published screen changed (including EOF).
    pub fn poll(self: *Session) !bool {
        try self.flush();
        var received = false;
        var budget: usize = 65536;
        var buf: [8192]u8 = undefined;
        while (!self.exited and budget > 0) {
            const n = c.read(self.fd, &buf, @min(buf.len, budget));
            if (n < 0) {
                const e = std.posix.errno(n);
                if (e == .AGAIN or e == .INTR) break;
                if (e == .IO) {
                    self.exited = true;
                    break;
                }
                return error.PtyRead;
            }
            if (n == 0) {
                self.exited = true;
                break;
            }
            budget -= @intCast(n);
            received = true;
            self.stream.nextSlice(buf[0..@intCast(n)]);
        }
        if (self.reply_error) |err| {
            self.reply_error = null;
            return err;
        }
        if (!received and self.exited == self.screen.exited) return false;
        return self.publish(self.screen.epoch);
    }

    pub fn resize(self: *Session, size: p.Size) !void {
        try size.validate();
        if (std.meta.eql(size, self.screen.size)) return;
        var ws = winsize(size);
        if (c.ioctl(self.fd, c.TIOCSWINSZ, &ws) < 0) return error.PtyResize;
        try self.terminal.resize(self.allocator, .{ .cols = size.cols, .rows = size.rows });
        _ = try self.publish(self.screen.epoch + 1);
    }

    fn publish(self: *Session, epoch: u64) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        var next = try self.capture(arena.allocator(), null, epoch);
        if (next.alternate_screen != self.screen.alternate_screen) next.epoch += 1;
        next.revision = self.screen.revision;
        if (equal(next, self.screen)) {
            arena.deinit();
            return false;
        }
        next.revision += 1;
        self.arena.deinit();
        self.arena = arena;
        self.screen = next;
        return true;
    }

    pub fn releaseAnchor(self: *Session, anchor: *?*vt.Pin) void {
        // History pins always belong to primary, even after switching active
        // screens. Epoch invalidation does not change the pin's owner.
        if (anchor.*) |pin| self.terminal.screens.get(.primary).?.pages.untrackPin(pin);
        anchor.* = null;
    }

    pub fn history(self: *Session, allocator: Allocator, anchor: *?*vt.Pin, epoch: u64, lines: i32) !struct { offset: u32, screen: p.Screen } {
        if (lines < -150 or lines > 150) return error.ScrollTooLarge;
        if (epoch != self.screen.epoch or self.screen.alternate_screen or lines == 0) {
            self.releaseAnchor(anchor);
            return .{ .offset = 0, .screen = self.screen };
        }
        const pages = &self.terminal.screens.active.pages;
        const live = pages.pointFromPin(.screen, pages.getTopLeft(.active)).?.screen.y;
        if (anchor.* == null) anchor.* = try pages.trackPin(pages.getTopLeft(.active));
        const current = if (anchor.*.?.garbage) 0 else if (pages.pointFromPin(.screen, anchor.*.?.*)) |pt| pt.screen.y else 0;
        const top: u32 = @intCast(std.math.clamp(@as(i64, current) - lines, 0, live));
        anchor.*.?.* = pages.pin(.{ .screen = .{ .x = 0, .y = top } }).?;
        var page = try self.capture(allocator, top, self.screen.epoch);
        page.revision = self.screen.revision;
        page.cursor = null;
        return .{ .offset = live - top, .screen = page };
    }

    fn capture(self: *Session, a: Allocator, top: ?u32, epoch: u64) !p.Screen {
        const t = &self.terminal;
        const rows = try a.alloc([]p.Cell, t.rows);
        const palette = &t.colors.palette.current;
        const default_fg = t.colors.foreground.get() orelse vt.color.RGB{ .r = 255, .g = 255, .b = 255 };
        const default_bg = t.colors.background.get() orelse vt.color.RGB{ .r = 0, .g = 0, .b = 0 };
        const reverse = t.modes.get(.reverse_colors);
        const foreground = if (reverse) default_bg else default_fg;
        const background = if (reverse) default_fg else default_bg;
        for (rows, 0..) |*row, y| {
            row.* = try a.alloc(p.Cell, t.cols);
            const pin = t.screens.active.pages.pin(if (top) |v| .{ .screen = .{ .x = 0, .y = v + @as(u32, @intCast(y)) } } else .{ .active = .{ .x = 0, .y = @intCast(y) } }).?;
            for (row.*, pin.cells(.all)) |*out, *cell| {
                const style = pin.style(cell);
                var text: std.ArrayList(u8) = .empty;
                var encoded: [4]u8 = undefined;
                const cp = cell.codepoint();
                try text.appendSlice(a, encoded[0..try std.unicode.utf8Encode(if (cp == 0) ' ' else cp, &encoded)]);
                if (pin.grapheme(cell)) |extra| for (extra) |ch| {
                    try text.appendSlice(a, encoded[0..try std.unicode.utf8Encode(ch, &encoded)]);
                };
                const fg = switch (style.fg_color) {
                    .none => foreground,
                    .rgb => |v| v,
                    .palette => |v| palette[v],
                };
                const bg = style.bg(cell, palette) orelse background;
                out.* = .{ .text = try text.toOwnedSlice(a), .width = switch (cell.wide) {
                    .wide => 2,
                    .spacer_tail => 0,
                    else => 1,
                }, .fg = rgb(fg), .bg = rgb(bg), .attributes = @as(u16, @bitCast(style.flags)) & 255, .underline = @intFromEnum(style.flags.underline) };
            }
        }
        const cursor = t.screens.active.cursor;
        return .{ .revision = 1, .epoch = epoch, .size = .{ .cols = t.cols, .rows = t.rows }, .rows = rows, .cursor = if (t.modes.get(.cursor_visible)) .{ .x = cursor.x, .y = cursor.y } else null, .application_cursor = t.modes.get(.cursor_keys), .bracketed_paste = t.modes.get(.bracketed_paste), .alternate_screen = t.screens.active_key == .alternate, .exited = self.exited };
    }
};

fn rgb(v: vt.color.RGB) [3]u8 {
    return .{ v.r, v.g, v.b };
}
fn winsize(size: p.Size) c.struct_winsize {
    return .{ .ws_col = size.cols, .ws_row = size.rows, .ws_xpixel = 0, .ws_ypixel = 0 };
}
fn reap(pid: c.pid_t) void {
    _ = c.kill(-pid, c.SIGKILL);
    _ = c.kill(pid, c.SIGKILL);
    var status: c_int = 0;
    while (c.waitpid(pid, &status, 0) < 0) {
        if (std.posix.errno(@as(c_int, -1)) != .INTR) break;
    }
}
fn equal(a: p.Screen, b: p.Screen) bool {
    if (a.epoch != b.epoch or !std.meta.eql(a.size, b.size) or !std.meta.eql(a.cursor, b.cursor) or a.application_cursor != b.application_cursor or a.bracketed_paste != b.bracketed_paste or a.alternate_screen != b.alternate_screen or a.exited != b.exited) return false;
    for (a.rows, b.rows) |ar, br| for (ar, br) |x, y| {
        if (!std.mem.eql(u8, x.text, y.text) or x.width != y.width or !std.meta.eql(x.fg, y.fg) or !std.meta.eql(x.bg, y.bg) or x.attributes != y.attributes or x.underline != y.underline) return false;
    };
    return true;
}

test "native PTY publication, Unicode style, history, resize and EOF" {
    const s = try Session.create(std.testing.allocator, std.testing.io, "/bin/sh", .{ .cols = 20, .rows = 4 });
    defer s.destroy();
    try s.input("stty -echo; printf '\\033[2J\\033[H\\033[1;38;2;1;2;3m界é\\033[0m'; sleep 1\n");
    var found = false;
    for (0..1000) |_| {
        _ = try s.poll();
        if (std.mem.eql(u8, s.screen.rows[0][0].text, "界")) {
            found = true;
            break;
        }
        var ready = c.struct_pollfd{ .fd = s.fd, .events = c.POLLIN, .revents = 0 };
        _ = c.poll(&ready, 1, 5);
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(u8, 2), s.screen.rows[0][0].width);
    try std.testing.expectEqual(@as(u8, 0), s.screen.rows[0][1].width);
    try std.testing.expectEqualStrings("é", s.screen.rows[0][2].text);
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, s.screen.rows[0][0].fg);
    try std.testing.expectEqual(@as(u16, 1), s.screen.rows[0][0].attributes);
    const revision = s.screen.revision;
    try std.testing.expect(!try s.poll());
    try std.testing.expectEqual(revision, s.screen.revision);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var anchor: ?*vt.Pin = null;
    defer s.releaseAnchor(&anchor);
    _ = try s.history(arena.allocator(), &anchor, s.screen.epoch, 1);
    try std.testing.expect(anchor != null);
    const epoch = s.screen.epoch;
    try s.resize(.{ .cols = 22, .rows = 5 });
    try std.testing.expectEqual(epoch + 1, s.screen.epoch);
    _ = try s.history(arena.allocator(), &anchor, epoch, 1);
    try std.testing.expect(anchor == null);
    try s.input("exit\n");
    for (0..1000) |_| {
        _ = try s.poll();
        if (s.screen.exited) break;
        var ready = c.struct_pollfd{ .fd = s.fd, .events = c.POLLIN, .revents = 0 };
        _ = c.poll(&ready, 1, 5);
    }
    try std.testing.expect(s.screen.exited);
}

test "input limits and shutdown of a stopped child" {
    const s = try Session.create(std.testing.allocator, std.testing.io, "/bin/sh", .{ .cols = 10, .rows = 2 });
    defer s.destroy();
    const batch = try std.testing.allocator.alloc(u8, 65537);
    defer std.testing.allocator.free(batch);
    @memset(batch, 'x');
    try std.testing.expectError(error.InputTooLarge, s.input(batch));
    for (0..16) |_| try s.input(batch[0..65536]);
    try std.testing.expectError(error.InputQueueFull, s.input("x"));
    // SIGKILL must work even before the child has completed setsid/exec,
    // and when job control has stopped it; destroy also waits/reaps.
    try std.testing.expectEqual(@as(c_int, 0), c.kill(s.child, c.SIGSTOP));
}

test "PATH shell, child environment, reverse defaults and alternate anchor release" {
    const s = try Session.create(std.testing.allocator, std.testing.io, "sh", .{ .cols = 30, .rows = 4 });
    defer s.destroy();
    // Check only the intended environment properties, never echo its contents.
    try s.input("stty -echo; if [ \"$TERM\" = xterm-256color ] && ! env | grep -q '^PS[12]='; then printf '\\033[2J\\033[H\\033[?5hOK\\033[38;2;1;2;3mX\\033[0m'; fi\n");
    for (0..1000) |_| {
        _ = try s.poll();
        if (std.mem.eql(u8, s.screen.rows[0][0].text, "O")) break;
        var ready = c.struct_pollfd{ .fd = s.fd, .events = c.POLLIN, .revents = 0 };
        _ = c.poll(&ready, 1, 5);
    }
    try std.testing.expectEqualStrings("O", s.screen.rows[0][0].text);
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, s.screen.rows[0][0].fg);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, s.screen.rows[0][0].bg);
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, s.screen.rows[0][2].fg);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var anchor: ?*vt.Pin = null;
    defer s.releaseAnchor(&anchor);
    _ = try s.history(arena.allocator(), &anchor, s.screen.epoch, 1);
    try std.testing.expect(anchor != null);
    const epoch = s.screen.epoch;
    try s.input("printf '\\033[?1049h'\n");
    for (0..1000) |_| {
        _ = try s.poll();
        if (s.screen.alternate_screen) break;
        var ready = c.struct_pollfd{ .fd = s.fd, .events = c.POLLIN, .revents = 0 };
        _ = c.poll(&ready, 1, 5);
    }
    try std.testing.expect(s.screen.alternate_screen);
    try std.testing.expectEqual(epoch + 1, s.screen.epoch);
    s.releaseAnchor(&anchor);
    try std.testing.expect(anchor == null);
    // Releasing again is safe, including while alternate remains active.
    s.releaseAnchor(&anchor);
}

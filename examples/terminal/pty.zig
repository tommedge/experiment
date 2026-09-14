// Adapted from ../editor/src/pty.zig. PTY and thread ownership stay example-local.
const std = @import("std");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
    @cInclude("pthread.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("util.h");
});

/// Callback runs on the IO thread and must only schedule work, never touch UI state.
pub const Wakeup = struct { context: *anyopaque, notify: *const fn (*anyopaque) callconv(.c) void };
/// UI-owned copy of queued output. EOF/error are delivered even without text.
pub const Batch = struct { bytes: []u8, eof: bool, failure: ?anyerror };
/// One PTY session with a cancellable nonblocking IO worker. Both directions are
/// queued under a mutex, keeping large writes and shutdown off the UI critical path.
pub const Pty = struct {
    allocator: std.mem.Allocator,
    master: c_int,
    child: c.pid_t,
    cancel: [2]c_int,
    mutex: c.pthread_mutex_t = undefined,
    thread: ?std.Thread = null,
    stopping: bool = false,
    eof: bool = false,
    failure: ?anyerror = null,
    wakeup: ?Wakeup,
    wakeup_pending: bool = false,
    output: std.ArrayList(u8) = .empty,
    input: std.ArrayList(u8) = .empty,
    input_offset: usize = 0,
    exit_status: ?c_int = null,
    const buffer_limit = 4 * 1024 * 1024;

    /// command[0] is an executable path. Empty command starts $SHELL (or /bin/sh)
    /// as an interactive login shell. All argv/env allocation occurs before fork.
    pub fn spawn(a: std.mem.Allocator, command: []const []const u8, wakeup: ?Wakeup) !*Pty {
        const self = try a.create(Pty);
        errdefer a.destroy(self);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const memory = arena.allocator();
        const shell = if (std.c.getenv("SHELL")) |value| std.mem.span(value) else "/bin/sh";
        const args: []const []const u8 = if (command.len == 0) &.{ shell, "-li" } else command;
        const executable = try executablePath(memory, args[0]);
        const argv = try memory.alloc(?[*:0]const u8, args.len + 1);
        for (args, 0..) |arg, i| argv[i] = (try memory.dupeZ(u8, arg)).ptr;
        argv[args.len] = null;
        var env: std.ArrayList(?[*:0]const u8) = .empty;
        var index: usize = 0;
        while (std.c.environ[index]) |entry| : (index += 1) {
            const bytes = std.mem.span(entry);
            if (std.mem.startsWith(u8, bytes, "TERM=") or std.mem.startsWith(u8, bytes, "COLORTERM=") or std.mem.startsWith(u8, bytes, "TERM_PROGRAM=")) continue;
            try env.append(memory, entry);
        }
        try env.appendSlice(memory, &.{ "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=zigui-terminal", null });
        var cancel: [2]c_int = undefined;
        if (c.pipe(&cancel) != 0) return error.PipeFailed;
        errdefer {
            _ = c.close(cancel[0]);
            _ = c.close(cancel[1]);
        }
        try nonblocking(cancel[0]);
        try nonblocking(cancel[1]);
        _ = c.fcntl(cancel[0], c.F_SETFD, @as(c_int, c.FD_CLOEXEC));
        _ = c.fcntl(cancel[1], c.F_SETFD, @as(c_int, c.FD_CLOEXEC));
        var master: c_int = -1;
        var size = c.struct_winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
        const child = c.forkpty(&master, null, null, &size);
        if (child < 0) return error.ForkFailed;
        if (child == 0) {
            // Only async-signal-safe calls after fork, including when AppKit has
            // started its own threads. No allocators or Objective-C runtime here.
            _ = c.close(cancel[0]);
            _ = c.close(cancel[1]);
            _ = c.execve(executable.ptr, @ptrCast(argv.ptr), @ptrCast(env.items.ptr));
            c._exit(127);
        }
        self.* = .{ .allocator = a, .master = master, .child = child, .cancel = cancel, .wakeup = wakeup };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) {
            _ = c.close(master);
            _ = c.kill(child, c.SIGKILL);
            _ = c.waitpid(child, null, 0);
            return error.MutexFailed;
        }
        errdefer {
            _ = c.close(master);
            _ = c.kill(-child, c.SIGKILL);
            _ = c.kill(child, c.SIGKILL);
            _ = c.waitpid(child, null, 0);
            _ = c.pthread_mutex_destroy(&self.mutex);
        }
        try nonblocking(master);
        _ = c.fcntl(master, c.F_SETFD, @as(c_int, c.FD_CLOEXEC));
        self.thread = try std.Thread.spawn(.{}, ioLoop, .{self});
        return self;
    }
    fn nonblocking(fd: c_int) !void {
        const flags = c.fcntl(fd, c.F_GETFL);
        if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.NonblockingFailed;
    }
    fn executablePath(a: std.mem.Allocator, name: []const u8) ![:0]const u8 {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidCommand;
        if (std.mem.indexOfScalar(u8, name, '/') != null) return a.dupeZ(u8, name);
        const path = if (std.c.getenv("PATH")) |value| std.mem.span(value) else "/usr/bin:/bin";
        var directories = std.mem.splitScalar(u8, path, ':');
        while (directories.next()) |directory| {
            const candidate = try a.dupeZ(u8, try std.fmt.allocPrint(a, "{s}/{s}", .{ if (directory.len == 0) "." else directory, name }));
            if (c.access(candidate.ptr, c.X_OK) == 0) return candidate;
        }
        return error.ExecutableNotFound;
    }
    fn lock(self: *Pty) void {
        const result = c.pthread_mutex_lock(&self.mutex);
        std.debug.assert(result == 0);
    }
    fn unlock(self: *Pty) void {
        const result = c.pthread_mutex_unlock(&self.mutex);
        std.debug.assert(result == 0);
    }
    fn poke(self: *Pty) void {
        if (self.cancel[1] < 0) return;
        const byte: u8 = 1;
        _ = c.write(self.cancel[1], &byte, 1);
    }
    pub fn write(self: *Pty, bytes: []const u8) !void {
        self.lock();
        defer self.unlock();
        if (self.stopping or self.eof) return error.PtyClosed;
        if (bytes.len > buffer_limit - self.input.items.len) return error.PtyInputLimit;
        try self.input.appendSlice(self.allocator, bytes);
        self.poke();
    }
    pub fn resize(self: *Pty, cols: u16, rows: u16, width: u16, height: u16) !void {
        var size = c.struct_winsize{ .ws_col = cols, .ws_row = rows, .ws_xpixel = width, .ws_ypixel = height };
        if (c.ioctl(self.master, c.TIOCSWINSZ, &size) != 0) return error.ResizeFailed;
    }
    pub fn drain(self: *Pty, a: std.mem.Allocator) !Batch {
        self.lock();
        defer self.unlock();
        const bytes = try a.dupe(u8, self.output.items);
        self.output.clearRetainingCapacity();
        self.wakeup_pending = false;
        self.poke(); // Resume a reader paused by output backpressure.
        return .{ .bytes = bytes, .eof = self.eof, .failure = self.failure };
    }
    fn notify(self: *Pty) void {
        self.lock();
        const wakeup = if (self.wakeup_pending) null else self.wakeup;
        self.wakeup_pending = true;
        self.unlock();
        if (wakeup) |wake| wake.notify(wake.context);
    }
    fn finish(self: *Pty, failure: ?anyerror) void {
        self.lock();
        self.eof = true;
        self.failure = failure;
        self.unlock();
        self.notify();
    }
    fn ioLoop(self: *Pty) void {
        var buffer: [8192]u8 = undefined;
        while (true) {
            self.lock();
            const stop = self.stopping;
            const writable = self.input_offset < self.input.items.len;
            const readable = self.output.items.len < buffer_limit;
            self.unlock();
            if (stop) return;
            var fds = [_]c.struct_pollfd{
                .{ .fd = if (readable or writable) self.master else -1, .events = @intCast(@as(c_int, if (readable) c.POLLIN else 0) | @as(c_int, if (writable) c.POLLOUT else 0)), .revents = 0 },
                .{ .fd = self.cancel[0], .events = c.POLLIN, .revents = 0 },
            };
            if (c.poll(&fds, fds.len, -1) < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                self.finish(error.PollFailed);
                return;
            }
            if (fds[1].revents != 0) while (c.read(self.cancel[0], &buffer, buffer.len) > 0) {};
            self.lock();
            const stopping = self.stopping;
            self.unlock();
            if (stopping) return;
            if (fds[0].revents & c.POLLNVAL != 0) {
                self.finish(error.InvalidPty);
                return;
            }
            if (!readable and fds[0].revents & (c.POLLHUP | c.POLLERR) != 0) {
                // HUP is level-triggered even when POLLIN is disabled. Wait for
                // a drain/cancel before reading the remaining kernel output.
                _ = c.poll(&fds[1], 1, -1);
                continue;
            }
            if (readable and fds[0].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) {
                while (true) {
                    self.lock();
                    const available = buffer_limit - self.output.items.len;
                    self.unlock();
                    if (available == 0) break;
                    const count = c.read(self.master, &buffer, @min(buffer.len, available));
                    if (count > 0) {
                        const len: usize = @intCast(count);
                        self.lock();
                        const result = self.output.appendSlice(self.allocator, buffer[0..len]);
                        self.unlock();
                        result catch |err| {
                            self.finish(err);
                            return;
                        };
                        self.notify();
                    } else if (count == 0) {
                        self.finish(null);
                        return;
                    } else {
                        const err = std.c._errno().*;
                        if (err == c.EINTR) continue;
                        if (err == c.EAGAIN) {
                            if (fds[0].revents & c.POLLHUP != 0) {
                                self.finish(null);
                                return;
                            }
                            break;
                        }
                        self.finish(if (err == c.EIO) null else error.ReadFailed);
                        return;
                    }
                }
            }
            if (fds[0].revents & c.POLLOUT != 0) {
                self.lock();
                const remaining = self.input.items[self.input_offset..];
                const count = if (remaining.len > 0) c.write(self.master, remaining.ptr, remaining.len) else 0;
                const err = if (count < 0) std.c._errno().* else 0;
                if (count > 0) self.input_offset += @intCast(count);
                if (self.input_offset == self.input.items.len) {
                    self.input.clearRetainingCapacity();
                    self.input_offset = 0;
                }
                self.unlock();
                if (count < 0 and err != c.EAGAIN and err != c.EINTR) {
                    self.finish(error.WriteFailed);
                    return;
                }
            }
        }
    }
    /// Join before closing descriptors, then reap the owned child. A stubborn
    /// shell gets a bounded HUP grace period rather than hanging window teardown.
    pub fn shutdown(self: *Pty) void {
        if (self.master < 0) return;
        self.lock();
        self.stopping = true;
        self.eof = true;
        self.unlock();
        self.poke();
        if (self.thread) |thread| thread.join();
        self.thread = null;
        const foreground = c.tcgetpgrp(self.master);
        if (foreground > 0 and foreground != self.child) _ = c.kill(-foreground, c.SIGHUP);
        _ = c.kill(-self.child, c.SIGHUP);
        _ = c.kill(self.child, c.SIGHUP);
        _ = c.close(self.master);
        self.master = -1;
        _ = c.close(self.cancel[0]);
        _ = c.close(self.cancel[1]);
        self.cancel = .{ -1, -1 };
        var status: c_int = 0;
        for (0..50) |_| {
            const result = c.waitpid(self.child, &status, c.WNOHANG);
            if (result == self.child) {
                self.exit_status = status;
                return;
            }
            if (result < 0 and std.c._errno().* != c.EINTR) return;
            _ = c.poll(null, 0, 10);
        }
        _ = c.kill(-self.child, c.SIGKILL);
        _ = c.kill(self.child, c.SIGKILL);
        while (c.waitpid(self.child, &status, 0) < 0) {
            if (std.c._errno().* != c.EINTR) return;
        }
        self.exit_status = status;
    }
    pub fn destroy(self: *Pty) void {
        self.shutdown();
        self.input.deinit(self.allocator);
        self.output.deinit(self.allocator);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.allocator.destroy(self);
    }
};

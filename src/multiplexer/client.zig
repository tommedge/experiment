const std = @import("std");
const quic = @import("quic");
const el = quic.event_loop;
const p = @import("protocol.zig");
const common = @import("common.zig");
const render = @import("render.zig");
const A = std.mem.Allocator;

const Handler = struct {
    pub const protocol: el.Protocol = .quic;
    allocator: A,
    hello: p.Hello,
    headless: bool,
    net: ?el.ClientSession = null,
    stream: u64 = 0,
    connected: i64 = 0,
    frames: common.Frames = .{},
    arena: std.heap.ArenaAllocator,
    history_arena: std.heap.ArenaAllocator,
    screen: ?p.Screen = null,
    history: ?p.Screen = null,
    id: u64 = 0,
    datagrams: usize = 0,
    snapshots: usize = 0,
    request: u64 = 0,
    scrolling: bool = false,
    detached: bool = false,
    listed: bool = false,
    failure: ?anyerror = null,

    fn deinit(self: *Handler) void {
        self.frames.deinit(self.allocator);
        self.arena.deinit();
        self.history_arena.deinit();
    }
    pub fn onConnected(self: *Handler, net: *el.ClientSession) void {
        self.net = net.*;
        self.connected = common.now();
        self.open(net) catch |err| {
            self.failure = err;
        };
    }
    fn open(self: *Handler, net: *el.ClientSession) !void {
        self.stream = try net.openStream();
        const bytes = try p.frame(self.allocator, self.hello);
        defer self.allocator.free(bytes);
        try net.writeStream(self.stream, bytes);
    }
    fn send(self: *Handler, message: p.ClientMessage) !void {
        const bytes = try p.frame(self.allocator, message);
        defer self.allocator.free(bytes);
        try (if (self.net) |*net| net else return error.NotConnected).writeStream(self.stream, bytes);
    }
    pub fn onStreamData(self: *Handler, _: *el.ClientSession, stream: u64, data: []const u8, fin: bool) void {
        self.receive(stream, data, fin) catch |err| {
            self.failure = err;
        };
    }
    fn receive(self: *Handler, stream: u64, data: []const u8, fin: bool) !void {
        if (stream != self.stream) return error.UnexpectedStream;
        try self.frames.append(self.allocator, data);
        while (try self.frames.peek()) |bytes| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            switch (try p.decode(p.ServerMessage, a, bytes)) {
                .sessions => |sessions| {
                    if (self.hello.request != .list) return error.UnexpectedSessionList;
                    for (sessions) |session| {
                        const line = if (session.creator) |creator| try std.fmt.allocPrint(a, "{d}\t{s}\t{s}\n", .{ session.id, creator.login_name, creator.node_id }) else try std.fmt.allocPrint(a, "{d}\n", .{session.id});
                        try render.write(1, line);
                    }
                    self.listed = true;
                },
                .attached => |id| self.id = id,
                .snapshot => |screen| {
                    try screen.validate();
                    self.snapshots += 1;
                    if (self.screen == null or screen.revision > self.screen.?.revision) try self.publish(screen);
                    try self.send(.{ .ack = self.screen.?.revision });
                },
                .err => |reason| {
                    std.debug.print("server: {s}\n", .{reason});
                    return error.ServerRejected;
                },
                .detached => self.detached = true,
                .scrollback => |view| {
                    try view.screen.validate();
                    if (self.scrolling and view.request == self.request and self.screen != null and view.screen.epoch == self.screen.?.epoch) {
                        self.scrolling = view.offset != 0;
                        const encoded = try p.encode(a, view.screen);
                        _ = self.history_arena.reset(.retain_capacity);
                        self.history = if (self.scrolling) try p.decode(p.Screen, self.history_arena.allocator(), encoded) else null;
                        try self.paint(self.history orelse self.screen.?, null);
                    }
                },
            }
            self.frames.consume(bytes.len);
        }
        if (fin and !self.detached and !self.listed) return error.ServerStreamClosed;
    }
    pub fn onDatagram(self: *Handler, _: *el.ClientSession, _: u64, bytes: []const u8) void {
        self.datagram(bytes) catch |err| {
            self.failure = err;
        };
    }
    fn datagram(self: *Handler, bytes: []const u8) !void {
        self.datagrams += 1;
        if (self.screen) |screen| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            // Apply only to a temporary row array. Atomic rejection preserves
            // the persistent screen, and publication owns all accepted text.
            var next = screen;
            next.rows = try arena.allocator().dupe([]p.Cell, screen.rows);
            if (try next.apply(try p.decode(p.Update, arena.allocator(), bytes))) try self.publish(next);
            try self.send(.{ .ack = self.screen.?.revision });
        }
    }
    fn publish(self: *Handler, screen: p.Screen) !void {
        if (self.screen) |old| {
            if (screen.epoch != old.epoch and self.scrolling) {
                self.request += 1;
                self.scrolling = false;
                self.history = null;
                try self.send(.{ .scroll = .{ .request = self.request, .epoch = screen.epoch, .lines = 0 } });
            }
        }
        if (!self.scrolling) try self.paint(screen, self.screen);
        const bytes = try p.encode(self.allocator, screen);
        defer self.allocator.free(bytes);
        _ = self.arena.reset(.retain_capacity);
        self.screen = try p.decode(p.Screen, self.arena.allocator(), bytes);
    }
    fn paint(self: *Handler, screen: p.Screen, previous: ?p.Screen) !void {
        if (self.headless) return;
        const bytes = try render.draw(self.allocator, screen, previous);
        defer self.allocator.free(bytes);
        try render.write(1, bytes);
    }
    fn scroll(self: *Handler, lines: i32) !void {
        const screen = self.screen orelse return;
        if (lines != 0 and screen.alternate_screen) return;
        if (lines < 0 and !self.scrolling) return;
        self.request += 1;
        self.scrolling = lines != 0;
        if (lines == 0) {
            self.history = null;
            try self.paint(screen, null);
        }
        try self.send(.{ .scroll = .{ .request = self.request, .epoch = screen.epoch, .lines = lines } });
    }
};

pub fn run(a: A, io: std.Io, options: anytype) !void {
    const address = try common.Address.parse(options.server);
    const cert = try std.Io.Dir.cwd().readFileAlloc(io, options.cert, a, .limited(1024 * 1024));
    defer a.free(cert);
    const parsed = try (std.crypto.Certificate{ .buffer = cert, .index = 0 }).parse();
    try parsed.verifyHostName("multiplexer");
    var pins: [1][32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(cert, &pins[0], .{});
    const token = if (options.tailscale) try a.alloc(u8, 0) else try std.Io.Dir.cwd().readFileAlloc(io, options.token_file, a, .limited(33));
    defer a.free(token);
    if (!options.tailscale and token.len != 32) return error.InvalidToken;
    const size = if (options.headless or options.command == .list) p.Size{ .cols = options.cols, .rows = options.rows } else try render.size();
    try size.validate();
    const request: p.Request = switch (options.command) {
        .list => .list,
        .new => .{ .create = size },
        .attach => .{ .attach = .{ .id = options.id.?, .size = size } },
        .serve => unreachable,
    };
    var handler = Handler{ .allocator = a, .hello = .{ .version = p.VERSION, .token = token, .request = request }, .headless = options.headless or options.command == .list, .arena = .init(a), .history_arena = .init(a) };
    defer handler.deinit();
    var client = try el.Client(Handler).init(a, &handler, .{
        .address = address.host,
        .port = address.port,
        .tls_config = .{ .cert_chain_der = &.{}, .private_key_bytes = &.{}, .alpn = &.{}, .server_name = "multiplexer", .cert_hashes = &pins, .skip_cert_verify = false },
        .conn_config = .{ .initial_max_streams_bidi = 1, .initial_max_streams_uni = 0, .keep_alive_period = 5000, .max_datagram_frame_size = 65536 },
    });
    defer {
        var net = client.clientSession();
        net.closeConnection();
        client.flush();
        client.deinit();
    }
    var guard: ?render.Guard = if (!handler.headless) try render.Guard.enter() else null;
    defer if (guard) |*g| g.leave();
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    var sent = options.send == null;
    var current_size = size;
    var escape_since: ?i64 = null;
    const start = common.now();
    var done = false;
    client.start();
    while (!done and !common.stopping()) {
        try client.tick();
        if (handler.failure) |err| return err;
        if (handler.listed) return;
        if (client.conn.isClosed()) return error.ConnectionClosed;
        if (handler.connected == 0 and common.now() - start > 10_000_000_000) return error.ConnectionTimeout;
        if (handler.connected != 0 and handler.headless and common.now() - handler.connected >= @as(i64, @intCast(options.timeout)) * 1_000_000_000) done = true;
        if (handler.screen) |screen| {
            if (!sent) {
                try handler.send(.{ .input = options.send.? });
                sent = true;
            }
            if (screen.exited) done = true;
            if (options.expect) |expected| {
                const text = try screen.text(a);
                defer a.free(text);
                if (std.mem.indexOf(u8, text, expected) != null) done = true;
            }
            if (!handler.headless) {
                const resized = try render.size();
                if (!std.meta.eql(resized, current_size)) {
                    try resized.validate();
                    try handler.scroll(0);
                    try handler.send(.{ .resize = resized });
                    current_size = resized;
                }
                var fd = common.c.struct_pollfd{ .fd = 0, .events = common.c.POLLIN, .revents = 0 };
                if (common.c.poll(&fd, 1, 0) > 0 and fd.revents & (common.c.POLLIN | common.c.POLLHUP) != 0) {
                    var bytes: [8192]u8 = undefined;
                    const n = common.c.read(0, &bytes, bytes.len);
                    if (n == 0) done = true else if (n > 0) {
                        if (input.items.len + @as(usize, @intCast(n)) > 65536) return error.InputTooLarge;
                        try input.appendSlice(a, bytes[0..@intCast(n)]);
                        escape_since = null;
                    }
                }
                while (try render.next(a, &input, screen.application_cursor, screen.bracketed_paste, @max(1, @as(i32, screen.size.rows) - 1))) |action| switch (action) {
                    .detach => {
                        done = true;
                        break;
                    },
                    .scroll => |lines| try handler.scroll(lines),
                    .live => try handler.scroll(0),
                    .input => |bytes| {
                        defer a.free(bytes);
                        if (bytes.len != 0) {
                            if (handler.scrolling) try handler.scroll(0);
                            try handler.send(.{ .input = bytes });
                        }
                    },
                };
                if (std.mem.eql(u8, input.items, "\x1b")) {
                    if (escape_since == null) escape_since = common.now();
                    if (common.now() - escape_since.? > 50_000_000) {
                        if (handler.scrolling) try handler.scroll(0) else try handler.send(.{ .input = "\x1b" });
                        input.clearRetainingCapacity();
                        escape_since = null;
                    }
                }
            }
        }
        var fd = common.c.struct_pollfd{ .fd = client.sockfd, .events = common.c.POLLIN, .revents = 0 };
        _ = common.c.poll(&fd, 1, 1);
    }
    const screen = handler.screen orelse return error.NoScreenReceived;
    var matched = true;
    if (handler.headless) {
        const text = try screen.text(a);
        defer a.free(text);
        try render.write(1, text);
        try render.write(1, "\n");
        std.debug.print("session={d} revision={d} datagrams={d} snapshots={d}\n", .{ handler.id, screen.revision, handler.datagrams, handler.snapshots });
        if (options.expect) |expected| matched = std.mem.indexOf(u8, text, expected) != null;
    }
    try handler.send(.detach);
    const deadline = common.now() + 5_000_000_000;
    while (!handler.detached) {
        try client.tick();
        if (handler.failure) |err| return err;
        if (common.now() > deadline) return error.DetachTimeout;
        var fd = common.c.struct_pollfd{ .fd = client.sockfd, .events = common.c.POLLIN, .revents = 0 };
        _ = common.c.poll(&fd, 1, 1);
    }
    if (!matched) return error.ExpectedTextNotFound;
}

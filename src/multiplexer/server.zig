const std = @import("std");
const quic = @import("quic");
const el = quic.event_loop;
const vt = @import("ghostty-vt");
const p = @import("protocol.zig");
const common = @import("common.zig");
const auth = @import("auth.zig");
const Session = @import("session.zig").Session;
const A = std.mem.Allocator;

const Entry = struct { session: *Session, creator: ?p.TailscaleIdentity };
const Sent = struct { revision: u64, bytes: []u8 };
const Peer = struct {
    net: el.Session,
    stream: u64,
    address: std.posix.sockaddr.storage,
    frames: common.Frames = .{},
    attached: ?usize = null,
    hello: bool = false,
    ended: bool = false,
    connected: i64,
    anchor: ?*vt.Pin = null,
    anchor_epoch: u64 = 0,
    baseline: ?[]u8 = null,
    baseline_revision: u64 = 0,
    sent: std.ArrayList(Sent) = .empty,
    snapshot_pending: ?u64 = null,
    last_sent: i64 = 0,
    pending_since: ?i64 = null,
};

const Handler = struct {
    pub const protocol: el.Protocol = .quic;
    allocator: A,
    io: std.Io,
    shell: []const u8,
    token: []const u8,
    tailscale: bool,
    allowed: []const []const u8,
    identities: std.heap.ArenaAllocator,
    sessions: std.ArrayList(Entry) = .empty,
    peers: std.AutoHashMap(u64, *Peer),

    fn deinit(self: *Handler) void {
        std.debug.assert(self.peers.count() == 0);
        self.peers.deinit();
        for (self.sessions.items) |entry| entry.session.destroy();
        self.sessions.deinit(self.allocator);
        self.identities.deinit();
    }

    pub fn onStreamData(self: *Handler, net: *el.Session, stream: u64, data: []const u8, fin: bool) void {
        self.receive(net, stream, data, fin) catch |err| {
            std.log.warn("connection: {s}", .{@errorName(err)});
            net.closeConnection();
        };
    }
    fn receive(self: *Handler, net: *el.Session, stream: u64, data: []const u8, fin: bool) !void {
        if (stream != 0) return error.UnexpectedStream;
        const peer = self.peers.get(net.id()) orelse blk: {
            const peer = try self.allocator.create(Peer);
            errdefer self.allocator.destroy(peer);
            peer.* = .{ .net = net.*, .stream = stream, .address = net.entry.conn.peerAddress().*, .connected = common.now() };
            try self.peers.put(net.id(), peer);
            break :blk peer;
        };
        if (peer.ended) return;
        try peer.frames.append(self.allocator, data);
        try self.drain(peer);
        if (fin and !peer.ended) {
            self.detach(peer);
            peer.net.closeQuicStream(stream);
            peer.ended = true;
        }
    }
    fn drain(self: *Handler, peer: *Peer) !void {
        if (self.tailscale and !std.mem.eql(u8, std.mem.asBytes(&peer.address), std.mem.asBytes(peer.net.entry.conn.peerAddress()))) return error.PeerAddressChanged;
        while (!peer.ended) {
            const bytes = (try peer.frames.peek()) orelse break;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            if (!peer.hello) {
                try self.hello(peer, a, try p.decode(p.Hello, a, bytes));
            } else {
                self.message(peer, a, try p.decode(p.ClientMessage, a, bytes)) catch |err| {
                    // Leave this frame at the head of the reliable queue until
                    // the PTY accepts it; later input cannot overtake it.
                    if (err == error.InputQueueFull) return;
                    return err;
                };
            }
            peer.frames.consume(bytes.len);
        }
    }
    fn send(self: *Handler, peer: *Peer, value: p.ServerMessage) !void {
        const bytes = try p.frame(self.allocator, value);
        defer self.allocator.free(bytes);
        try peer.net.writeStream(peer.stream, bytes);
    }
    fn fail(self: *Handler, peer: *Peer, reason: []const u8) !void {
        self.detach(peer);
        try self.send(peer, .{ .err = reason });
        peer.net.closeQuicStream(peer.stream);
        peer.ended = true;
    }
    fn hello(self: *Handler, peer: *Peer, a: A, h: p.Hello) !void {
        if (h.version != p.VERSION) return self.fail(peer, "authentication failed or incompatible protocol");
        var creator: ?p.TailscaleIdentity = null;
        if (self.tailscale) {
            if (h.token.len != 0) return self.fail(peer, "authentication failed or incompatible protocol");
            // Migration is disabled before consulting the daemon: authorization
            // remains bound to the actual authenticated QUIC peer address.
            peer.net.entry.conn.local_params.disable_active_migration = true;
            const address = peer.net.entry.conn.peerAddress();
            var host: [common.c.INET6_ADDRSTRLEN]u8 = undefined;
            const addr: *const quic.sockaddr.Address = @ptrCast(@alignCast(address));
            const ip: *const anyopaque = if (addr.any.family == std.posix.AF.INET) @ptrCast(&addr.in.sa.addr) else @ptrCast(&addr.in6.sa.addr);
            _ = common.c.inet_ntop(addr.any.family, ip, &host, host.len) orelse return error.InvalidPeerAddress;
            const endpoint = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}:{d}", .{ if (addr.any.family == std.posix.AF.INET) "" else "[", std.mem.sliceTo(&host, 0), if (addr.any.family == std.posix.AF.INET) "" else "]", addr.getPort() });
            defer self.allocator.free(endpoint);
            creator = auth.authorize(a, self.io, endpoint, self.allowed) catch return self.fail(peer, "authentication failed or incompatible protocol");
        } else {
            if (h.token.len != 32 or !std.crypto.timing_safe.eql([32]u8, h.token[0..32].*, self.token[0..32].*)) return self.fail(peer, "authentication failed or incompatible protocol");
        }
        peer.hello = true;
        switch (h.request) {
            .list => {
                const infos = try self.allocator.alloc(p.SessionInfo, self.sessions.items.len);
                defer self.allocator.free(infos);
                for (infos, self.sessions.items, 0..) |*info, entry, index| info.* = .{ .id = index + 1, .creator = entry.creator };
                try self.send(peer, .{ .sessions = infos });
                peer.net.closeQuicStream(peer.stream);
                peer.ended = true;
            },
            .create => |size| {
                if (self.sessions.items.len == 64) return self.fail(peer, "session limit reached (64)");
                size.validate() catch return self.fail(peer, "invalid terminal size");
                if (creator) |identity| creator = .{
                    .login_name = try self.identities.allocator().dupe(u8, identity.login_name),
                    .user_id = identity.user_id,
                    .node_id = try self.identities.allocator().dupe(u8, identity.node_id),
                };
                const session = Session.create(self.allocator, self.io, self.shell, size) catch return self.fail(peer, "could not create PTY");
                self.sessions.append(self.allocator, .{ .session = session, .creator = creator }) catch |err| {
                    session.destroy();
                    return err;
                };
                peer.attached = self.sessions.items.len - 1;
                try self.send(peer, .{ .attached = self.sessions.items.len });
                try self.snapshot(peer, session.screen);
            },
            .attach => |request| {
                if (request.id == 0 or request.id > self.sessions.items.len) return self.fail(peer, "unknown session");
                const index: usize = @intCast(request.id - 1);
                self.sessions.items[index].session.resize(request.size) catch return self.fail(peer, "invalid terminal size");
                peer.attached = index;
                try self.send(peer, .{ .attached = request.id });
                try self.snapshot(peer, self.sessions.items[index].session.screen);
            },
        }
    }
    fn message(self: *Handler, peer: *Peer, a: A, m: p.ClientMessage) !void {
        const session = self.sessions.items[peer.attached orelse return error.NotAttached].session;
        switch (m) {
            .input => |bytes| if (!session.screen.exited) try session.input(bytes),
            .resize => |size| try session.resize(size),
            .ack => |revision| {
                for (peer.sent.items) |sent| if (sent.revision == revision) {
                    if (revision <= peer.baseline_revision) return;
                    const bytes = try self.allocator.dupe(u8, sent.bytes);
                    if (peer.baseline) |old| self.allocator.free(old);
                    peer.baseline = bytes;
                    peer.baseline_revision = revision;
                    if (peer.snapshot_pending) |pending| if (revision >= pending) {
                        peer.snapshot_pending = null;
                    };
                    break;
                };
            },
            .detach => {
                self.detach(peer);
                try self.send(peer, .detached);
                peer.net.closeQuicStream(peer.stream);
                peer.ended = true;
            },
            .scroll => |scroll| {
                self.anchorEpoch(peer, session);
                const view = try session.history(a, &peer.anchor, scroll.epoch, scroll.lines);
                try self.send(peer, .{ .scrollback = .{ .request = scroll.request, .offset = view.offset, .screen = view.screen } });
            },
        }
    }
    fn anchorEpoch(_: *Handler, peer: *Peer, session: *Session) void {
        if (peer.anchor_epoch != session.screen.epoch) {
            session.releaseAnchor(&peer.anchor);
            peer.anchor_epoch = session.screen.epoch;
        }
    }
    fn detach(self: *Handler, peer: *Peer) void {
        if (peer.attached) |index| self.sessions.items[index].session.releaseAnchor(&peer.anchor);
        peer.attached = null;
    }
    fn remember(self: *Handler, peer: *Peer, screen: p.Screen) !void {
        if (peer.sent.items.len > 0 and peer.sent.items[peer.sent.items.len - 1].revision == screen.revision) return;
        const bytes = try p.encode(self.allocator, screen);
        errdefer self.allocator.free(bytes);
        if (peer.sent.items.len == 32) self.allocator.free(peer.sent.orderedRemove(0).bytes);
        try peer.sent.append(self.allocator, .{ .revision = screen.revision, .bytes = bytes });
    }
    fn snapshot(self: *Handler, peer: *Peer, screen: p.Screen) !void {
        try self.send(peer, .{ .snapshot = screen });
        try self.remember(peer, screen);
        peer.snapshot_pending = screen.revision;
        peer.last_sent = common.now();
    }
    fn replicate(self: *Handler, peer: *Peer) !void {
        if (self.tailscale and !std.mem.eql(u8, std.mem.asBytes(&peer.address), std.mem.asBytes(peer.net.entry.conn.peerAddress()))) return error.PeerAddressChanged;
        if (peer.ended or peer.attached == null) return;
        const session = self.sessions.items[peer.attached.?].session;
        self.anchorEpoch(peer, session);
        if (peer.snapshot_pending != null) return;
        const screen = session.screen;
        if (peer.baseline_revision == screen.revision) {
            peer.pending_since = null;
            return;
        }
        const now = common.now();
        if (peer.pending_since == null) peer.pending_since = now;
        const rtt = @divTrunc(peer.net.getStats().smoothed_rtt_ns, 2);
        const fresh = peer.sent.items[peer.sent.items.len - 1].revision != screen.revision;
        const pace = std.math.clamp(rtt, if (fresh) @as(i64, 1_000_000) else 20_000_000, 250_000_000);
        if (now - peer.last_sent < pace or now - peer.pending_since.? < 1_000_000) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const baseline = try p.decode(p.Screen, a, peer.baseline orelse return);
        const update = (try screen.diff(a, baseline)) orelse return self.snapshot(peer, screen);
        const bytes = try p.encode(a, update);
        const limit = peer.net.entry.conn.maxDatagramPayloadSize() orelse 0;
        if (bytes.len > limit or (peer.sent.items.len == 32 and baseline.revision < peer.sent.items[0].revision)) return self.snapshot(peer, screen);
        try peer.net.sendQuicDatagram(bytes);
        try self.remember(peer, screen);
        peer.last_sent = now;
    }
    pub fn onConnectionClosed(self: *Handler, net: *el.Session) void {
        const peer = if (self.peers.fetchRemove(net.id())) |entry| entry.value else return;
        self.detach(peer);
        peer.frames.deinit(self.allocator);
        if (peer.baseline) |bytes| self.allocator.free(bytes);
        for (peer.sent.items) |sent| self.allocator.free(sent.bytes);
        peer.sent.deinit(self.allocator);
        self.allocator.destroy(peer);
    }
};

pub fn run(a: A, io: std.Io, options: anytype) !void {
    const address = try common.Address.parse(options.bind);
    if (options.tailscale) try auth.checkTailscale(a, io, address.host, options.allowed.items);
    var credentials = try auth.load(a, io, options.state, options.tailscale);
    defer credentials.deinit();
    var handler = Handler{ .allocator = a, .io = io, .shell = options.shell, .token = credentials.token, .tailscale = options.tailscale, .allowed = options.allowed.items, .identities = .init(a), .peers = .init(a) };
    defer handler.deinit();
    const chain = [_][]const u8{credentials.cert};
    var server = try el.Server(Handler).init(a, &handler, .{
        .address = address.host,
        .port = address.port,
        .ipv6 = std.mem.indexOfScalar(u8, address.host, ':') != null,
        .tls_config = .{ .cert_chain_der = &chain, .private_key_bytes = credentials.key.bytes, .private_key_algorithm = credentials.key.algorithm, .alpn = &.{} },
        .conn_config = .{ .initial_max_streams_bidi = 1, .initial_max_streams_uni = 0, .keep_alive_period = 5000, .max_datagram_frame_size = 65536 },
    });
    defer server.deinit();
    std.debug.print("listening on {s} (UDP/QUIC); credentials in {s}\n", .{ options.bind, options.state });
    server.start();
    while (!common.stopping()) {
        try server.tick();
        for (handler.sessions.items) |entry| _ = try entry.session.poll();
        var peers = handler.peers.valueIterator();
        while (peers.next()) |ptr| {
            const peer = ptr.*;
            if (!peer.hello and common.now() - peer.connected > 10_000_000_000) {
                peer.net.closeConnection();
                continue;
            }
            handler.drain(peer) catch |err| {
                handler.fail(peer, @errorName(err)) catch peer.net.closeConnection();
            };
            handler.replicate(peer) catch peer.net.closeConnection();
        }
        // Bound timer latency while allowing output/socket readiness to wake us.
        var fds: [65]common.c.struct_pollfd = undefined;
        fds[0] = .{ .fd = server.sockfd, .events = common.c.POLLIN, .revents = 0 };
        for (handler.sessions.items, 1..) |entry, i| fds[i] = .{ .fd = if (entry.session.screen.exited) -1 else entry.session.fd, .events = common.c.POLLIN, .revents = 0 };
        _ = common.c.poll(&fds, @intCast(handler.sessions.items.len + 1), 1);
    }
    // This server owns its loop: stop flushes CONNECTION_CLOSE, and deinit
    // tears down the loop. isStopped() is only a shared-loop completion gate.
    server.stop();
}

const std = @import("std");
const quic = @import("quic");
const p = @import("protocol.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const Ed = std.crypto.sign.Ed25519;

pub const Credentials = struct {
    allocator: A,
    cert: []const u8,
    key_der: []const u8,
    key: quic.tls13.PrivateKey,
    token: []const u8,

    pub fn deinit(self: *Credentials) void {
        self.allocator.free(self.cert);
        self.allocator.free(self.key_der);
        self.allocator.free(self.token);
        self.* = undefined;
    }
};

fn read(a: A, io: Io, dir: Io.Dir, name: []const u8) !?[]u8 {
    return dir.readFileAlloc(io, name, a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn write(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(io, name, .{ .exclusive = true, .permissions = @enumFromInt(0o600) });
    defer file.close(io);
    errdefer dir.deleteFile(io, name) catch {};
    try file.writeStreamingAll(io, bytes);
}

pub fn load(a: A, io: Io, state: []const u8, tailscale: bool) !Credentials {
    const dir = try Io.Dir.cwd().createDirPathOpen(io, state, .{ .permissions = @enumFromInt(0o700), .open_options = .{ .iterate = true } });
    defer dir.close(io);
    try dir.setPermissions(io, @enumFromInt(0o700));
    var cert = try read(a, io, dir, "cert.der");
    errdefer if (cert) |b| a.free(b);
    var key_der = try read(a, io, dir, "key.der");
    errdefer if (key_der) |b| a.free(b);
    if ((cert == null) != (key_der == null)) return error.IncompleteCredentials;
    if (cert == null) {
        const generated = try generate(a, io);
        cert = generated.cert;
        key_der = generated.key_der;
        try write(io, dir, "key.der", key_der.?);
        errdefer dir.deleteFile(io, "key.der") catch {};
        try write(io, dir, "cert.der", cert.?);
    }
    const key = try quic.tls13.extractPrivateKey(key_der.?);
    if (!try quic.tls13.keyMatchesCertificate(key, cert.?)) return error.KeyCertificateMismatch;
    const token = if (tailscale) try a.alloc(u8, 0) else blk: {
        if (try read(a, io, dir, "token")) |b| break :blk b;
        const b = try a.alloc(u8, 32);
        errdefer a.free(b);
        try io.randomSecure(b);
        try write(io, dir, "token", b);
        break :blk b;
    };
    errdefer a.free(token);
    if (!tailscale and token.len != 32) return error.InvalidToken;
    return .{ .allocator = a, .cert = cert.?, .key_der = key_der.?, .key = key, .token = token };
}

// Every intermediate TLV belongs to a short-lived arena; only final DER escapes.
fn tlv(a: A, tag: u8, parts: []const []const u8) ![]const u8 {
    var n: usize = 0;
    for (parts) |part| n += part.len;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, tag);
    if (n < 128) try out.append(a, @intCast(n)) else {
        var length: [@sizeOf(usize)]u8 = undefined;
        var v = n;
        var i: usize = length.len;
        while (v != 0) : (v >>= 8) {
            i -= 1;
            length[i] = @truncate(v);
        }
        try out.append(a, 0x80 | @as(u8, @intCast(length.len - i)));
        try out.appendSlice(a, length[i..]);
    }
    for (parts) |part| try out.appendSlice(a, part);
    return out.toOwnedSlice(a);
}

fn generate(a: A, io: Io) !struct { cert: []u8, key_der: []u8 } {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    var seed: [32]u8 = undefined;
    try io.randomSecure(&seed);
    const kp = try Ed.KeyPair.generateDeterministic(seed);
    const alg = try tlv(t, 0x30, &.{&.{ 0x06, 0x03, 0x2b, 0x65, 0x70 }});
    const name = try tlv(t, 0x30, &.{try tlv(t, 0x31, &.{try tlv(t, 0x30, &.{ &.{ 0x06, 3, 0x55, 4, 3 }, try tlv(t, 0x0c, &.{"multiplexer"}) })})});
    const validity = try tlv(t, 0x30, &.{ try tlv(t, 0x18, &.{"19700101000000Z"}), try tlv(t, 0x18, &.{"40960101000000Z"}) });
    const pubkey = kp.public_key.toBytes();
    const spki = try tlv(t, 0x30, &.{ alg, try tlv(t, 3, &.{ &.{0}, &pubkey }) });
    const san = try tlv(t, 0x30, &.{try tlv(t, 0x82, &.{"multiplexer"})});
    const extensions = try tlv(t, 0xa3, &.{try tlv(t, 0x30, &.{try tlv(t, 0x30, &.{ &.{ 6, 3, 0x55, 0x1d, 0x11 }, try tlv(t, 4, &.{san}) })})});
    const tbs = try tlv(t, 0x30, &.{ &.{ 0xa0, 3, 2, 1, 2 }, &.{ 2, 1, 1 }, alg, name, validity, name, spki, extensions });
    const signature = (try kp.sign(tbs, null)).toBytes();
    const cert = try a.dupe(u8, try tlv(t, 0x30, &.{ tbs, alg, try tlv(t, 3, &.{ &.{0}, &signature }) }));
    errdefer a.free(cert);
    const key_der = try a.dupe(u8, try tlv(t, 0x30, &.{ &.{ 2, 1, 0 }, alg, try tlv(t, 4, &.{try tlv(t, 4, &.{&seed})}) }));
    return .{ .cert = cert, .key_der = key_der };
}

const Outcome = union(enum) { result: std.process.RunError!std.process.RunResult, timeout: Io.Cancelable!void };
fn query(a: A, io: Io, argv: []const []const u8) !std.json.Parsed(std.json.Value) {
    const deadline = (Io.Timeout{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }).toDeadline(io);
    var buffer: [2]Outcome = undefined;
    var select = Io.Select(Outcome).init(io, &buffer);
    defer while (select.cancel()) |remaining| {
        if (remaining == .result) if (remaining.result) |r| {
            a.free(r.stdout);
            a.free(r.stderr);
        } else |_| {};
    };
    try select.concurrent(.timeout, Io.Timeout.sleep, .{ deadline, io });
    try select.concurrent(.result, std.process.run, .{ a, io, std.process.RunOptions{ .argv = argv, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024), .timeout = deadline } });
    const outcome = try select.await();
    if (outcome == .timeout) return error.Timeout;
    const result = try outcome.result;
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TailscaleFailed;
    return std.json.parseFromSlice(std.json.Value, a, result.stdout, .{ .allocate = .alloc_always });
}

fn field(v: std.json.Value, name: []const u8) !std.json.Value {
    if (v != .object) return error.InvalidTailscaleResponse;
    return v.object.get(name) orelse error.InvalidTailscaleResponse;
}
fn string(v: std.json.Value) ![]const u8 {
    if (v != .string) return error.InvalidTailscaleResponse;
    return v.string;
}
fn integer(v: std.json.Value) !u64 {
    return switch (v) {
        .integer => |i| std.math.cast(u64, i) orelse error.InvalidTailscaleResponse,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch error.InvalidTailscaleResponse,
        else => error.InvalidTailscaleResponse,
    };
}
fn validateAllowed(allowed: []const []const u8) !void {
    if (allowed.len == 0) return error.NoAllowedUsers;
    for (allowed) |user| if (std.mem.trim(u8, user, " \t\r\n").len == 0) return error.NoAllowedUsers;
}

pub fn checkTailscale(a: A, io: Io, host: []const u8, allowed: []const []const u8) !void {
    try validateAllowed(allowed);
    const ip = try Io.net.IpAddress.parse(host, 0);
    switch (ip) {
        .ip4 => |v| if (std.mem.allEqual(u8, &v.bytes, 0)) return error.InvalidTailscaleBind,
        .ip6 => |v| if (std.mem.allEqual(u8, &v.bytes, 0)) return error.InvalidTailscaleBind,
    }
    const parsed = try query(a, io, &.{ "tailscale", "status", "--json", "--peers=false" });
    defer parsed.deinit();
    if (!std.mem.eql(u8, try string(try field(parsed.value, "BackendState")), "Running")) return error.TailscaleNotRunning;
    const tun = try field(parsed.value, "TUN");
    if (tun != .bool or !tun.bool) return error.TailscaleNotRunning;
    const ips = try field(try field(parsed.value, "Self"), "TailscaleIPs");
    if (ips != .array) return error.InvalidTailscaleResponse;
    var matched = false;
    for (ips.array.items) |item| {
        const candidate = try Io.net.IpAddress.parse(try string(item), 0);
        matched = matched or ip.eql(&candidate);
    }
    if (!matched) return error.InvalidTailscaleBind;
}

fn identity(a: A, value: std.json.Value, allowed: []const []const u8) !p.TailscaleIdentity {
    try validateAllowed(allowed);
    const node = try field(value, "Node");
    const profile = try field(value, "UserProfile");
    if (node != .object) return error.InvalidTailscaleResponse;
    if (node.object.get("Tags")) |tags| {
        if (tags != .array or tags.array.items.len != 0) return error.TaggedDevice;
    }
    const id = try string(try field(node, "StableID"));
    const user = try integer(try field(node, "User"));
    const login = try string(try field(profile, "LoginName"));
    if (id.len == 0 or user == 0 or user != try integer(try field(profile, "ID"))) return error.Unauthorized;
    for (allowed) |entry| if (std.mem.eql(u8, entry, login)) {
        const login_copy = try a.dupe(u8, login);
        errdefer a.free(login_copy);
        return .{ .login_name = login_copy, .user_id = user, .node_id = try a.dupe(u8, id) };
    };
    return error.Unauthorized;
}

pub fn authorize(a: A, io: Io, peer: []const u8, allowed: []const []const u8) !p.TailscaleIdentity {
    try validateAllowed(allowed);
    const parsed = try query(a, io, &.{ "tailscale", "whois", "--json", "--proto=udp", peer });
    defer parsed.deinit();
    const result = try identity(a, parsed.value, allowed);
    std.debug.print("Tailscale connection: user={s} node={s} peer={s}\n", .{ result.login_name, result.node_id, peer });
    return result;
}

test "native Ed25519 certificate signature and PKCS8" {
    const a = std.testing.allocator;
    const generated = try generate(a, std.testing.io);
    defer a.free(generated.cert);
    defer a.free(generated.key_der);
    const key = try quic.tls13.extractPrivateKey(generated.key_der);
    try std.testing.expect(try quic.tls13.keyMatchesCertificate(key, generated.cert));
    const parsed = try (std.crypto.Certificate{ .buffer = generated.cert, .index = 0 }).parse();
    try parsed.verifyHostName("multiplexer");
    const kp = try Ed.KeyPair.generateDeterministic(key.bytes[0..32].*);
    const sig = Ed.Signature.fromBytes(parsed.signature()[0..64].*);
    try sig.verify(parsed.slice(parsed.message_slice), kp.public_key);
}

test "credential reload, private modes, missing half and Tailscale ignores token" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var first = try load(a, io, path, false);
    defer first.deinit();
    var second = try load(a, io, path, false);
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.cert, second.cert);
    try std.testing.expectEqualSlices(u8, first.key_der, second.key_der);
    try std.testing.expectEqualSlices(u8, first.token, second.token);
    try std.testing.expectEqual(@as(usize, 32), first.token.len);
    try std.testing.expectEqual(@as(u32, 0o700), (try tmp.dir.stat(io)).permissions.toMode() & 0o777);
    for ([_][]const u8{ "cert.der", "key.der", "token" }) |name| {
        try std.testing.expectEqual(@as(u32, 0o600), (try tmp.dir.statFile(io, name, .{})).permissions.toMode() & 0o777);
    }
    try tmp.dir.deleteFile(io, "token");
    // A directory cannot be read as a token file: success proves no token read.
    try tmp.dir.createDir(io, "token", @enumFromInt(0o700));
    var ts = try load(a, io, path, true);
    defer ts.deinit();
    try std.testing.expectEqual(@as(usize, 0), ts.token.len);
    try tmp.dir.deleteFile(io, "key.der");
    try std.testing.expectError(error.IncompleteCredentials, load(a, io, path, true));
}

test "Tailscale validation rejects blank users and malformed identity" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NoAllowedUsers, checkTailscale(a, std.testing.io, "100.64.0.1", &.{" "}));
    try std.testing.expectError(error.NoAllowedUsers, authorize(a, std.testing.io, "100.64.0.1:9", &.{}));
    const malformed = try std.json.parseFromSlice(std.json.Value, a, "{\"Node\":{\"StableID\":\"n\",\"User\":1,\"Tags\":[\"tag:x\"]},\"UserProfile\":{\"ID\":1,\"LoginName\":\"alice\"}}", .{});
    defer malformed.deinit();
    try std.testing.expectError(error.TaggedDevice, identity(a, malformed.value, &.{"alice"}));
}

test "CLI query fails closed and times out even after output pipes close" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.TailscaleFailed, query(a, io, &.{ "/bin/sh", "-c", "exit 1" }));
    try std.testing.expectError(error.Timeout, query(a, io, &.{ "/bin/sh", "-c", "exec 1>&- 2>&-; exec sleep 30" }));
}

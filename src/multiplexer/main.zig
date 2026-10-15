const std = @import("std");
const common = @import("common.zig");
const p = @import("protocol.zig");

// QUIC's packet-level tracing must not corrupt an interactive terminal.
pub const std_options: std.Options = .{ .log_level = .warn };

const Options = struct {
    command: enum { serve, list, new, attach },
    id: ?u64 = null,
    bind: []const u8 = "127.0.0.1:4433",
    server: []const u8 = "127.0.0.1:4433",
    state: []const u8 = ".multiplexer",
    shell: []const u8 = "/bin/sh",
    cert: []const u8 = ".multiplexer/cert.der",
    token_file: []const u8 = ".multiplexer/token",
    tailscale: bool = false,
    allowed: std.ArrayList([]const u8) = .empty,
    headless: bool = false,
    send: ?[]const u8 = null,
    expect: ?[]const u8 = null,
    timeout: u64 = 2,
    cols: u16 = 80,
    rows: u16 = 24,
};

const usage =
    \\Persistent PTYs with native Zig Ghostty screen replication over QUIC.
    \\
    \\Usage: multiplexer-zig serve|list|new|attach ID [options]
    \\
    \\serve:   --bind IP:PORT --state DIR --shell PATH
    \\         --tailscale --allow-user LOGIN (repeatable)
    \\clients: --server IP:PORT --cert FILE --token-file FILE | --tailscale
    \\new/attach: --headless [--send TEXT] [--expect TEXT] [--timeout SECONDS]
    \\            [--cols 1..300] [--rows 1..150]
    \\
    \\Defaults: 127.0.0.1:4433, .multiplexer credentials, /bin/sh, 80x24, 2s.
    \\Ctrl+] detaches. Wheel and Shift+PageUp/PageDown browse history.
    \\Esc or input returns live. IPv6 addresses use [IP]:PORT.
    \\
;

fn parse(a: std.mem.Allocator, args: []const []const u8) !Options {
    if (args.len == 0) return error.MissingCommand;
    var o: Options = .{ .command = std.meta.stringToEnum(@FieldType(Options, "command"), args[0]) orelse return error.UnknownCommand };
    errdefer o.allowed.deinit(a);
    var token_explicit = false;
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        var name = args[i];
        if (!std.mem.startsWith(u8, name, "--")) {
            if (o.command != .attach or o.id != null) return error.UnexpectedArgument;
            o.id = try std.fmt.parseInt(u64, name, 10);
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, name, '=');
        const inline_value = if (equals) |idx| name[idx + 1 ..] else null;
        if (equals) |idx| name = name[0..idx];
        if (!std.mem.eql(u8, name, "--allow-user")) {
            if (seen.contains(name)) return error.DuplicateOption;
            try seen.put(name, {});
        }
        if (std.mem.eql(u8, name, "--tailscale")) {
            if (inline_value != null) return error.UnexpectedValue;
            o.tailscale = true;
            continue;
        }
        if (std.mem.eql(u8, name, "--headless") and (o.command == .new or o.command == .attach)) {
            if (inline_value != null) return error.UnexpectedValue;
            o.headless = true;
            continue;
        }
        const value = inline_value orelse blk: {
            i += 1;
            if (i == args.len) return error.MissingValue;
            break :blk args[i];
        };
        if (o.command == .serve) {
            if (std.mem.eql(u8, name, "--bind")) o.bind = value else if (std.mem.eql(u8, name, "--state")) o.state = value else if (std.mem.eql(u8, name, "--shell")) o.shell = value else if (std.mem.eql(u8, name, "--allow-user")) try o.allowed.append(a, value) else return error.UnknownOption;
        } else {
            if (std.mem.eql(u8, name, "--server")) o.server = value else if (std.mem.eql(u8, name, "--cert")) o.cert = value else if (std.mem.eql(u8, name, "--token-file")) {
                o.token_file = value;
                token_explicit = true;
            } else if (o.command != .list) {
                if (std.mem.eql(u8, name, "--send")) o.send = value else if (std.mem.eql(u8, name, "--expect")) o.expect = value else if (std.mem.eql(u8, name, "--timeout")) o.timeout = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, name, "--cols")) o.cols = try std.fmt.parseInt(u16, value, 10) else if (std.mem.eql(u8, name, "--rows")) o.rows = try std.fmt.parseInt(u16, value, 10) else return error.UnknownOption;
            } else return error.UnknownOption;
        }
    }
    if (o.command == .attach and o.id == null) return error.MissingSessionId;
    if (o.command == .serve and o.tailscale != (o.allowed.items.len != 0)) return error.TailscaleRequiresAllowUser;
    if (o.tailscale and token_explicit) return error.ConflictingAuthOptions;
    if (!o.headless and (o.send != null or o.expect != null)) return error.HeadlessRequired;
    if (o.timeout > std.math.maxInt(i64) / 1_000_000_000) return error.InvalidTimeout;
    try (p.Size{ .cols = o.cols, .rows = o.rows }).validate();
    _ = try common.Address.parse(if (o.command == .serve) o.bind else o.server);
    return o;
}

pub fn main(init: std.process.Init) void {
    execute(init) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
fn execute(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    };
    var options = parse(init.gpa, args[1..]) catch |err| {
        std.debug.print("{s}\n", .{usage});
        return err;
    };
    defer options.allowed.deinit(init.gpa);
    common.signals();
    if (options.command == .serve) try @import("server.zig").run(init.gpa, init.io, options) else try @import("client.zig").run(init.gpa, init.io, options);
}

test "CLI contract and option constraints" {
    const a = std.testing.allocator;
    var o = try parse(a, &.{ "attach", "--headless", "19", "--cols=103", "--rows", "31", "--send", "echo hello\n", "--timeout", "7" });
    defer o.allowed.deinit(a);
    try std.testing.expectEqual(@as(?u64, 19), o.id);
    try std.testing.expectEqual(@as(u16, 103), o.cols);
    try std.testing.expectEqual(@as(u16, 31), o.rows);
    try std.testing.expectError(error.HeadlessRequired, parse(a, &.{ "new", "--expect", "hello" }));
    try std.testing.expectError(error.ConflictingAuthOptions, parse(a, &.{ "list", "--tailscale", "--token-file", "secret" }));
    try std.testing.expectError(error.TailscaleRequiresAllowUser, parse(a, &.{ "serve", "--allow-user", "someone" }));
    try std.testing.expectError(error.InvalidSize, parse(a, &.{ "new", "--rows", "151" }));
    try std.testing.expectError(error.DuplicateOption, parse(a, &.{ "new", "--cols", "20", "--cols", "30" }));
}

test {
    _ = @import("protocol.zig");
    _ = @import("common.zig");
    _ = @import("render.zig");
    _ = @import("session.zig");
    _ = @import("auth.zig");
}

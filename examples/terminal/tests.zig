const std = @import("std");
const ui = @import("zigui");
const model = @import("model.zig");
const t = std.testing;
const Pty = @import("pty.zig").Pty;
const macos = @import("macos.zig");
const c = @cImport({
    @cInclude("poll.h");
    @cInclude("sys/wait.h");
    @cInclude("errno.h");
});

fn fontsForTest() !*ui.TextSystem {
    const backend = try ui.text.stub.create(t.allocator);
    errdefer backend.deinit();
    return ui.TextSystem.create(t.allocator, backend);
}
fn engineForTest(fonts: *ui.TextSystem) !*model.Engine {
    return model.Engine.create(t.allocator, std.Io.Threaded.global_single_threaded.io(), fonts);
}

test "terminal parses output without a PTY and paints through zigui" {
    const backend = try ui.text.stub.create(std.testing.allocator);
    const fonts = ui.TextSystem.create(std.testing.allocator, backend) catch |err| {
        backend.deinit();
        return err;
    };
    defer fonts.release();
    var app = ui.App.init(std.testing.allocator);
    defer app.deinit();
    app.setTextSystem(fonts);
    const engine = try model.Engine.create(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), fonts);
    const entity = app.create(model.Model{ .engine = engine }) catch |err| {
        engine.destroy();
        return err;
    };
    try app.updateWith(entity, @as([]const u8, "hello\x1b[31m red\x1b[0m"), model.Model.output);
    var window = try ui.Window.init(&app, entity, .{ .width = 640, .height = 480 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try std.testing.expect(window.renderer.backend.scene.primitives.items.len > 5);
    const cells = engine.render_state.row_data.items(.cells)[0].slice();
    try std.testing.expectEqual(@as(u21, 'h'), cells.items(.raw)[0].codepoint());
}

test "terminal replies are scoped to each VT instance" {
    const fonts = try fontsForTest();
    defer fonts.release();
    const a = try engineForTest(fonts);
    defer a.destroy();
    const b = try engineForTest(fonts);
    defer b.destroy();
    try a.feed("A\x1b[6n");
    try b.feed("BC\x1b[6n");
    try t.expectEqualStrings("\x1b[1;2R", a.writes.items);
    try t.expectEqualStrings("\x1b[1;3R", b.writes.items);
}

test "cell rendering preserves graphemes, wide columns, backgrounds and box geometry" {
    const fonts = try fontsForTest();
    defer fonts.release();
    const engine = try engineForTest(fonts);
    defer engine.destroy();
    try engine.resize(.{ .size = .{ .width = 160, .height = 60 }, .scale = 1 });
    try engine.feed("\x1b[?25le\u{301}界z\r\n┌─┐\r\n\x1b[48;5;236mAB\x1b[0m\x1b[7mC\x1b[0m");
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    app.setTextSystem(fonts);
    var frame = try ui.Frame.init(&app, engine.metrics.size, 1);
    defer frame.deinit();
    try frame.draw(try frame.element(model.Grid{ .engine = engine }));
    var base = false;
    var accent = false;
    var wide = false;
    var z = false;
    var horizontal = false;
    var background = false;
    var inverse = false;
    for (frame.scene.primitives.items) |primitive| switch (primitive) {
        .glyph => |glyph| {
            if (glyph.glyph_id == 'e') base = true;
            if (glyph.glyph_id == 0x301) accent = true;
            if (glyph.glyph_id == '界') {
                wide = true;
                try t.expectEqual(engine.cell_width * 2, glyph.clip.size.width);
            }
            if (glyph.glyph_id == 'z') {
                z = true;
                try t.expectEqual(engine.cell_width * 3, glyph.position.x);
            }
            if (glyph.glyph_id == 'C') {
                inverse = true;
                try t.expectEqualDeep(model.color(engine.render_state.colors.background), glyph.color);
            }
            try t.expect(glyph.glyph_id != 0x2500);
        },
        .quad => |quad| {
            if (quad.bounds.origin.x == engine.cell_width and quad.bounds.origin.y == 29 and quad.bounds.size.width == engine.cell_width and quad.bounds.size.height == 1) horizontal = true;
            // Adjacent equal backgrounds are now one two-cell run.
            if (quad.bounds.origin.y == 40 and quad.bounds.size.width == engine.cell_width * 2 and @abs(quad.color.r - 0.0295568) < 0.0001) background = true;
        },
    };
    try t.expect(base and accent and wide and z and horizontal and background and inverse);
}

test "terminal key encoding follows application cursor, control, alt and Kitty modes" {
    const fonts = try fontsForTest();
    defer fonts.release();
    const engine = try engineForTest(fonts);
    defer engine.destroy();
    _ = try engine.event(.{ .key_down = .{ .key = "up", .key_code = 126, .modifiers = .{} } });
    try t.expectEqualStrings("\x1b[A", engine.writes.items);
    engine.writes.clearRetainingCapacity();
    try engine.feed("\x1b[?1h");
    _ = try engine.event(.{ .key_down = .{ .key = "up", .key_code = 126, .modifiers = .{} } });
    try t.expectEqualStrings("\x1bOA", engine.writes.items);
    engine.writes.clearRetainingCapacity();
    _ = try engine.event(.{ .key_down = .{ .key = "c", .key_code = 8, .modifiers = .{ .control = true } } });
    try t.expectEqualStrings("\x03", engine.writes.items);
    engine.writes.clearRetainingCapacity();
    _ = try engine.event(.{ .key_down = .{ .key = "f", .key_code = 3, .modifiers = .{ .alt = true } } });
    try t.expectEqualStrings("\x1bf", engine.writes.items);
    engine.writes.clearRetainingCapacity();
    _ = try engine.event(.{ .key_down = .{ .key = "space", .key_code = 49, .modifiers = .{ .control = true } } });
    try t.expectEqualStrings("\x00", engine.writes.items);
    engine.writes.clearRetainingCapacity();
    try t.expect(!try engine.event(.{ .key_down = .{ .key = "ф", .key_code = 0, .modifiers = .{} } }));
    _ = try engine.event(.{ .text = .{ .text = "ф" } });
    try t.expectEqualStrings("ф", engine.writes.items);
    engine.writes.clearRetainingCapacity();
    try engine.feed("\x1b[>1u");
    _ = try engine.event(.{ .key_down = .{ .key = "a", .key_code = 0, .modifiers = .{ .control = true } } });
    try t.expectEqualStrings("\x1b[97;5u", engine.writes.items);
}

test "terminal alternate screen, scrollback, bracketed paste and preedit" {
    const fonts = try fontsForTest();
    defer fonts.release();
    const engine = try engineForTest(fonts);
    defer engine.destroy();
    try engine.resize(.{ .size = .{ .width = 160, .height = 60 }, .scale = 1 });
    try engine.feed("primary\x1b[?1049halternate");
    try t.expectEqual(.alternate, engine.render_state.screen);
    try engine.feed("\x1b[?1049l");
    var contents = try @import("main.zig").viewportText(t.allocator, engine);
    try t.expect(std.mem.indexOf(u8, contents, "primary") != null);
    t.allocator.free(contents);
    try engine.feed("\r\n1\r\n2\r\n3\r\n4");
    _ = try engine.event(.{ .scroll = .{ .position = .{}, .delta = .{ .y = 20 }, .precise = false, .modifiers = .{} } });
    contents = try @import("main.zig").viewportText(t.allocator, engine);
    defer t.allocator.free(contents);
    try t.expect(std.mem.indexOf(u8, contents, "primary") != null);
    try engine.feed("\x1b[?2004h");
    try engine.paste("a\nb");
    try t.expectEqualStrings("\x1b[200~a\nb\x1b[201~", engine.writes.items);
    engine.writes.clearRetainingCapacity();
    _ = try engine.event(.{ .marked_text = .{ .text = "é", .selection = .{ .location = 1, .length = 0 }, .replacement = null } });
    try t.expectEqual(@as(usize, 0), engine.writes.items.len);
    try t.expect(!try engine.event(.{ .key_down = .{ .key = "enter", .key_code = 36, .modifiers = .{} } }));
    _ = try engine.event(.{ .text = .{ .text = "é" } });
    try t.expectEqualStrings("é", engine.writes.items);
    try t.expectEqual(@as(usize, 0), engine.preedit.len);
}

test "terminal SGR mouse reporting uses grid coordinates and wheel buttons" {
    const fonts = try fontsForTest();
    defer fonts.release();
    const engine = try engineForTest(fonts);
    defer engine.destroy();
    try engine.feed("\x1b[?1000h\x1b[?1006h");
    const position = ui.geometry.Point{ .x = engine.cell_width * 2 + 1, .y = model.line_height + 1 };
    _ = try engine.event(.{ .mouse_down = .{ .position = position, .button = .left } });
    _ = try engine.event(.{ .mouse_up = .{ .position = position, .button = .left } });
    _ = try engine.event(.{ .scroll = .{ .position = position, .delta = .{ .y = 1 }, .precise = false, .modifiers = .{} } });
    try t.expectEqualStrings("\x1b[<0;3;2M\x1b[<0;3;2m\x1b[<64;3;2M", engine.writes.items);
}

fn waitFor(process: *Pty, output: *std.ArrayList(u8), marker: ?[]const u8) !void {
    for (0..500) |_| {
        const batch = try process.drain(t.allocator);
        defer t.allocator.free(batch.bytes);
        if (batch.failure) |err| return err;
        try output.appendSlice(t.allocator, batch.bytes);
        if (marker) |text| {
            if (std.mem.indexOf(u8, output.items, text) != null) return;
        }
        if (batch.eof) {
            if (marker != null) return error.MarkerMissing;
            return;
        }
        _ = c.poll(null, 0, 10);
    }
    return error.PtyTimedOut;
}
test "real PTY carries input, environment and window dimensions and reaps its child" {
    const process = try Pty.spawn(t.allocator, &.{ "/bin/sh", "-c", "stty -echo; printf READY; IFS= read -r line; printf '\\n%s:%s\\n' \"$TERM\" \"$line\"; stty size; exit 7" }, null);
    defer process.destroy();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(t.allocator);
    try waitFor(process, &output, "READY");
    try process.resize(91, 33, 910, 660);
    try process.write("ping\n");
    try waitFor(process, &output, null);
    try t.expect(std.mem.indexOf(u8, output.items, "xterm-256color:ping") != null);
    try t.expect(std.mem.indexOf(u8, output.items, "33 91") != null);
    process.shutdown();
    try t.expectEqual(@as(c_int, 7), (process.exit_status.? >> 8) & 0xff);
    try t.expect(c.waitpid(process.child, null, c.WNOHANG) < 0);
}

test "PTY cancellation interrupts blocked polling and terminates an uncooperative child" {
    const process = try Pty.spawn(t.allocator, &.{ "/bin/sh", "-c", "trap '' HUP; printf READY; while :; do sleep 1; done" }, null);
    defer process.destroy();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(t.allocator);
    try waitFor(process, &output, "READY");
    process.shutdown();
    try t.expect(process.thread == null and process.master == -1);
    try t.expect(process.exit_status != null);
    try t.expect(c.waitpid(process.child, null, c.WNOHANG) < 0);
}

test "PTY output backpressure drains a burst larger than the queue without dropping bytes" {
    const process = try Pty.spawn(t.allocator, &.{ "/bin/sh", "-c", "exec /bin/dd if=/dev/zero bs=1048576 count=5 2>/dev/null" }, null);
    defer process.destroy();
    _ = c.poll(null, 0, 100);
    var total: usize = 0;
    var eof = false;
    for (0..1000) |_| {
        const batch = try process.drain(t.allocator);
        defer t.allocator.free(batch.bytes);
        if (batch.failure) |err| return err;
        for (batch.bytes) |byte| try t.expectEqual(@as(u8, 0), byte);
        total += batch.bytes.len;
        if (batch.eof) {
            eof = true;
            break;
        }
        _ = c.poll(null, 0, 5);
    }
    try t.expect(eof);
    try t.expectEqual(@as(usize, 5 * 1048576), total);
}

test "queued UI wakeups are drained safely after the producer has stopped" {
    const Producer = struct {
        fn run(bridge: *macos.WakeBridge) void {
            for (0..10) |_| macos.WakeBridge.notify(bridge);
        }
        fn deliver(ptr: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(ptr));
            count.* += 1;
        }
    };
    var delivered: usize = 0;
    var bridge = macos.WakeBridge{ .context = &delivered, .deliver = Producer.deliver };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&bridge});
    thread.join();
    bridge.detachAndDrain();
    try t.expectEqual(@as(usize, 0), bridge.pending.load(.acquire));
    try t.expectEqual(@as(usize, 0), delivered);
}

/// Stable-address test host for notification and row-cache behavior.
const CachedTerminal = struct {
    app: ui.App,
    fonts: *ui.TextSystem,
    engine: *model.Engine,
    entity: ui.Entity(model.Model),
    window: ui.Window,
    fn init(self: *@This(), columns: usize, rows: usize) !void {
        self.app = .init(t.allocator);
        errdefer self.app.deinit();
        self.fonts = try fontsForTest();
        errdefer self.fonts.release();
        self.app.setTextSystem(self.fonts);
        self.engine = try engineForTest(self.fonts);
        self.entity = self.app.create(model.Model{ .engine = self.engine }) catch |err| {
            self.engine.destroy();
            return err;
        };
        const size = ui.geometry.Size{ .width = self.engine.cell_width * @as(f32, @floatFromInt(columns)), .height = model.line_height * @as(f32, @floatFromInt(rows)) };
        try self.app.updateWith(self.entity, ui.platform.Metrics{ .size = size, .scale = 1 }, model.Model.resize);
        self.window = try ui.Window.init(&self.app, self.entity, size, 1);
    }
    fn deinit(self: *@This()) void {
        self.window.deinit();
        self.app.deinit();
        self.fonts.release();
    }
    fn output(self: *@This(), bytes: []const u8) !void {
        try self.app.updateWith(self.entity, bytes, model.Model.output);
    }
    fn input(self: *@This(), event: ui.input.PlatformInput) !bool {
        var handled = false;
        try self.app.updateWith(self.entity, model.Model.Input{ .event = event, .handled = &handled }, model.Model.input);
        return handled;
    }
    fn draw(self: *@This()) !void {
        _ = try self.window.drawIfNeeded();
    }
};

test "handled input does not redraw the old screen before clear output arrives" {
    var h: CachedTerminal = undefined;
    try h.init(16, 4);
    defer h.deinit();
    try h.output("\x1b[?25lAAAAAAAAAAAA\r\nBBBBBBBBBBBB\r\nCCCCCCCCCCCC\r\nDDDDDDDDDDDD");
    try h.draw();
    const revision = h.app.revision(h.entity.id);
    const rebuilt = h.engine.row_cache.rebuilt;
    const misses = h.engine.shapes.misses;
    const frames = h.window.renderer.backend.presented_frames;
    try t.expect(try h.input(.{ .key_down = .{ .key = "l", .key_code = 37, .modifiers = .{ .control = true } } }));
    try t.expect(try h.input(.{ .key_up = .{ .key = "l", .key_code = 37, .modifiers = .{ .control = true } } }));
    try t.expect(try h.input(.{ .text = .{ .text = "clear" } }));
    try t.expect(try h.input(.{ .key_down = .{ .key = "enter", .key_code = 36, .modifiers = .{} } }));
    try t.expectEqualStrings("\x0cclear\r", h.engine.writes.items);
    try t.expectEqual(revision, h.app.revision(h.entity.id));
    try t.expect(!try h.window.drawIfNeeded());
    try t.expectEqual(frames, h.window.renderer.backend.presented_frames);
    try t.expectEqual(rebuilt, h.engine.row_cache.rebuilt);
    try h.output("\x1b[H\x1b[2J\x1b[3J");
    try t.expect(h.window.needsDraw());
    try h.draw();
    try t.expectEqual(@as(usize, 1), h.window.renderer.backend.scene.primitives.items.len);
    try t.expectEqual(misses, h.engine.shapes.misses); // Erasing text never shapes it again.
    try t.expectEqual(frames + 1, h.window.renderer.backend.presented_frames);
    try h.output("\x1b[31m");
    try t.expect(!h.window.needsDraw()); // Changing future text attributes alone is not visible.
    // A title/query/mode change still takes effect, without a graphics notification.
    try h.output("\x1b]2;new title\x07\x1b[6n\x1b[?1000h");
    try t.expectEqualStrings("new title", h.engine.terminal.getTitle().?);
    try h.draw(); // Accommodate any VT-wide invalidation associated with mode changes.
    const mouse_revision = h.app.revision(h.entity.id);
    try t.expect(try h.input(.{ .mouse_down = .{ .position = .{ .x = 1, .y = 1 }, .button = .left } }));
    try t.expectEqual(mouse_revision, h.app.revision(h.entity.id));
}

test "dirty row rebuilds are selective and cursor preedit focus changes reuse rows" {
    var h: CachedTerminal = undefined;
    try h.init(16, 4);
    defer h.deinit();
    try h.output("\x1b[?25lAAAA\r\nBBBB\r\nCCCC\r\nDDDD");
    try h.draw();
    try t.expectEqual(@as(usize, 4), h.engine.row_cache.rebuilt);
    const first = h.engine.row_cache.scenes[0].primitives.items.ptr;
    const third = h.engine.row_cache.scenes[2].primitives.items.ptr;
    try h.output("\x1b[2;2HX");
    try h.draw();
    try t.expectEqual(@as(usize, 5), h.engine.row_cache.rebuilt);
    try t.expectEqual(first, h.engine.row_cache.scenes[0].primitives.items.ptr);
    try t.expectEqual(third, h.engine.row_cache.scenes[2].primitives.items.ptr);
    try h.output("\x1b[?25h");
    try h.draw();
    const before = h.engine.row_cache.rebuilt;
    try h.output("\x1b[1;1H");
    try h.draw();
    try t.expectEqual(before, h.engine.row_cache.rebuilt);
    try h.app.updateWith(h.entity, false, model.Model.focus);
    try h.draw();
    try t.expectEqual(before, h.engine.row_cache.rebuilt);
    _ = try h.input(.{ .marked_text = .{ .text = "é", .selection = .{ .location = 1, .length = 0 }, .replacement = null } });
    try h.draw();
    try t.expectEqual(before, h.engine.row_cache.rebuilt);
    _ = try h.input(.{ .unmark_text = {} });
    try h.draw();
    try t.expectEqual(before, h.engine.row_cache.rebuilt);
}

test "multiple output batches accumulate dirty rows and cache failures preserve old row scenes" {
    var h: CachedTerminal = undefined;
    try h.init(16, 4);
    defer h.deinit();
    try h.output("\x1b[?25lAAAA\r\nBBBB\r\nCCCC\r\nDDDD");
    try h.draw();
    const first = h.engine.row_cache.scenes[0].primitives.items.ptr;
    const second = h.engine.row_cache.scenes[1].primitives.items.ptr;
    const snapshot = h.window.inspect().?;
    try h.output("\x1b[1;1HX");
    try h.output("\x1b[2;1HY");
    // Description + scene allocation for row 0 succeed; row 1's scene fails.
    var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 3 });
    h.engine.row_cache.allocator = failing.allocator();
    defer h.engine.row_cache.allocator = t.allocator;
    try t.expectError(error.OutOfMemory, h.window.drawIfNeeded());
    try t.expectEqual(first, h.engine.row_cache.scenes[0].primitives.items.ptr);
    try t.expectEqual(second, h.engine.row_cache.scenes[1].primitives.items.ptr);
    try t.expect(h.window.inspect().? == snapshot);
    try t.expect(h.engine.render_state.row_data.items(.dirty)[0]);
    try t.expect(h.engine.render_state.row_data.items(.dirty)[1]);
    try t.expectEqual(@as(usize, 4), h.engine.row_cache.rebuilt);
    h.engine.row_cache.allocator = t.allocator;
    try h.draw();
    try t.expectEqual(@as(usize, 6), h.engine.row_cache.rebuilt);
    try t.expectEqual(@as(u32, 'X'), h.engine.row_cache.scenes[0].primitives.items[0].glyph.glyph_id);
    try t.expectEqual(@as(u32, 'Y'), h.engine.row_cache.scenes[1].primitives.items[0].glyph.glyph_id);
}

test "background runs merge and retained shapes bypass the generic shaping LRU" {
    var h: CachedTerminal = undefined;
    try h.init(16, 3);
    defer h.deinit();
    h.fonts.cache_capacity = 1;
    try h.output("\x1b[?25l\x1b[48;5;236mABCDE\x1b[48;5;237mFG\x1b[0m\r\ne\u{301}界e\u{301}界");
    try h.draw();
    const row = h.engine.row_cache.scenes[0].primitives.items;
    try t.expectEqual(@as(usize, 9), row.len); // Two background runs plus seven glyphs.
    try t.expectEqual(h.engine.cell_width * 5, row[0].quad.bounds.size.width);
    try t.expectEqual(h.engine.cell_width * 2, row[1].quad.bounds.size.width);
    const misses = h.engine.shapes.misses;
    const shape_calls = h.fonts.shape_calls;
    // Redraw identical data through a dirty VT row, including non-ASCII clusters.
    try h.output("\x1b[2;1He\u{301}界e\u{301}界");
    try h.draw();
    try t.expectEqual(misses, h.engine.shapes.misses);
    try t.expectEqual(shape_calls, h.fonts.shape_calls);
    // With no VT changes, no cell lookup/build occurs at all.
    const hits = h.engine.shapes.hits;
    const rebuilt = h.engine.row_cache.rebuilt;
    h.window.invalidate();
    try h.draw();
    try t.expectEqual(hits, h.engine.shapes.hits);
    try t.expectEqual(rebuilt, h.engine.row_cache.rebuilt);
}

test "row caches invalidate for palette viewport screen resize and text generation changes" {
    var h: CachedTerminal = undefined;
    try h.init(16, 3);
    defer h.deinit();
    try h.output("\x1b[?25l\x1b[31mR\x1b[0m\r\n1\r\n2");
    try h.draw();
    const before = h.engine.row_cache.rebuilt;
    try h.output("\x1b]4;1;rgb:00/ff/00\x07");
    try h.draw();
    try t.expectEqual(before + 3, h.engine.row_cache.rebuilt);
    try t.expectEqual(@as(f32, 1), h.engine.row_cache.scenes[0].primitives.items[0].glyph.color.g);
    try h.output("\r\n3\r\n4");
    try h.draw();
    _ = try h.input(.{ .scroll = .{ .position = .{}, .delta = .{ .y = 10 }, .precise = false, .modifiers = .{} } });
    try h.draw();
    try t.expectEqual(@as(u32, 'R'), h.engine.row_cache.scenes[0].primitives.items[0].glyph.glyph_id);
    // Typing while scrolled back really changes the viewport and must notify.
    _ = try h.input(.{ .text = .{ .text = "x" } });
    try t.expect(h.window.needsDraw());
    try h.draw();
    try h.output("\x1b[?1049h\x1b[HALT");
    try h.draw();
    try t.expectEqual(@as(u32, 'A'), h.engine.row_cache.scenes[0].primitives.items[0].glyph.glyph_id);
    try h.output("\x1b[?1049l");
    try h.draw();
    const metrics = ui.platform.Metrics{ .size = .{ .width = 160, .height = 80 }, .scale = 2 };
    try h.window.resize(metrics.size, metrics.scale);
    try h.app.updateWith(h.entity, metrics, model.Model.resize);
    try h.draw();
    try t.expectEqual(@as(usize, 4), h.engine.row_cache.scenes.len);
    const resized = h.engine.row_cache.rebuilt;
    const misses = h.engine.shapes.misses;
    h.fonts.clearCache();
    try h.draw();
    try t.expectEqual(resized + 4, h.engine.row_cache.rebuilt);
    try t.expect(h.engine.shapes.misses > misses);
}

test "non-ASCII shape cache is bounded and retains lines independently of the generic cache" {
    const fonts = try fontsForTest();
    defer fonts.release();
    fonts.cache_capacity = 0;
    const font = try fonts.fontId(.{});
    const ids = [4]ui.FontId{ font, font, font, font };
    var shapes = @import("render_cache.zig").Shapes.init(t.allocator);
    defer shapes.deinit();
    for (0..1025) |i| _ = try shapes.get(fonts, ids, model.font_size, 0, @intCast(0x400 + i), &.{});
    try t.expectEqual(@as(u32, 1024), shapes.other.count());
    const calls = fonts.shape_calls;
    _ = try shapes.get(fonts, ids, model.font_size, 0, 0x800, &.{});
    try t.expectEqual(calls, fonts.shape_calls);
    _ = try shapes.get(fonts, ids, model.font_size, 0, 0x400, &.{});
    try t.expectEqual(calls + 1, fonts.shape_calls);
    const ascii = try shapes.get(fonts, ids, model.font_size, 0, 'a', &.{});
    try t.expectEqual(ascii, try shapes.get(fonts, ids, model.font_size, 0, 'a', &.{}));
}

fn shapeAllocationScenario(a: std.mem.Allocator) !void {
    const backend = try ui.text.stub.create(a);
    const fonts = ui.TextSystem.create(a, backend) catch |err| {
        backend.deinit();
        return err;
    };
    defer fonts.release();
    const font = try fonts.fontId(.{});
    var shapes = @import("render_cache.zig").Shapes.init(a);
    defer shapes.deinit();
    const ids = [4]ui.FontId{ font, font, font, font };
    _ = try shapes.get(fonts, ids, model.font_size, 0, 'a', &.{});
    _ = try shapes.get(fonts, ids, model.font_size, 0, 'e', &.{0x301});
    _ = try shapes.get(fonts, ids, model.font_size, 0, '界', &.{});
    _ = try shapes.get(fonts, ids, model.font_size, 0, 'e', &.{0x301});
}
test "shape-cache allocation failures release copied keys and retained line layouts" {
    try t.checkAllAllocationFailures(t.allocator, shapeAllocationScenario, .{});
}

test "row replay applies the current origin and clip without modifying cached primitives" {
    var h: CachedTerminal = undefined;
    try h.init(16, 3);
    defer h.deinit();
    try h.output("\x1b[?25lAAAA\r\nBBBB");
    try h.draw();
    const rebuilt = h.engine.row_cache.rebuilt;
    var frame = try ui.Frame.init(&h.app, .{ .width = 100, .height = 100 }, 1);
    defer frame.deinit();
    const grid = try frame.element(model.Grid{ .engine = h.engine });
    const root = try frame.div(.{ .style = .{ .width = .{ .px = 80 }, .height = .{ .px = 30 }, .padding = .{ .left = 7, .top = 9 }, .clip = true }, .children = &.{grid} });
    try frame.draw(root);
    try t.expectEqual(rebuilt, h.engine.row_cache.rebuilt);
    const glyph = frame.scene.primitives.items[1].glyph;
    try t.expectEqual(@as(f32, 7), glyph.position.x);
    try t.expectEqual(h.engine.baseline + 9, glyph.position.y);
    try t.expectEqual(@as(f32, 7), glyph.clip.origin.x);
    try t.expectEqual(@as(f32, 9), glyph.clip.origin.y);
    try t.expectEqual(@as(f32, 0), h.engine.row_cache.scenes[0].primitives.items[0].glyph.position.x);
}

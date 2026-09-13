const std = @import("std");
const t = std.testing;
const ui = @import("root.zig");
const ts = ui.text;

fn stub(a: std.mem.Allocator) !*ts.TextSystem {
    const backend = try @import("text/stub.zig").create(a);
    errdefer backend.deinit();
    return ts.TextSystem.create(a, backend);
}

test "portable shaping cache owns lines through eviction and validates UTF-8 runs" {
    const service = try stub(t.allocator);
    defer service.release();
    service.cache_capacity = 1;
    const font = try service.fontId(.{});
    const value = "aé🐳";
    const runs = [_]ts.FontRun{.{ .len = value.len, .font_id = font }};
    const a = try service.shapeLine(value, 20, &runs);
    defer a.release();
    const again = try service.shapeLine(value, 20, &runs);
    defer again.release();
    try t.expect(a == again);
    try t.expectEqual(@as(usize, 1), service.shape_calls);
    const b = try service.shapeLine("z", 20, &.{.{ .len = 1, .font_id = font }});
    defer b.release();
    try t.expectEqualStrings(value, a.text);
    try t.expectEqual(@as(f32, 36), a.width);
    try t.expectEqual(@as(usize, 3), a.closestIndexForX(24));
    try t.expectEqual(@as(f32, 24), a.xForIndex(3));
    try t.expect(a.indexForX(100) == null);
    try t.expectError(error.InvalidUtf8, service.shapeLine("\xff", 20, &.{.{ .len = 1, .font_id = font }}));
    try t.expectError(error.InvalidTextRuns, service.shapeLine("é", 20, &.{ .{ .len = 1, .font_id = font }, .{ .len = 1, .font_id = font } }));
    try t.expectError(error.InvalidSize, service.shapeLine(value, 0, &runs));
    try t.expectError(error.InvalidFontId, service.fontMetrics(@enumFromInt(999)));
}

test "multiline wrapping preserves UTF-8, combining clusters, empty lines and CRLF" {
    const service = try stub(t.allocator);
    defer service.release();
    const font = try service.fontId(.{});
    const value = "ab cd\r\né\n\ne\u{301}x";
    const shaped = try service.layoutText(t.allocator, value, 10, &.{.{ .len = value.len, .font_id = font }}, 18, 12);
    defer shaped.destroy();
    try t.expectEqual(@as(usize, 5), shaped.lines.items.len);
    try t.expectEqualStrings("ab ", shaped.lines.items[0].layout.text);
    try t.expectEqualStrings("cd", shaped.lines.items[1].layout.text);
    try t.expectEqualStrings("é", shaped.lines.items[2].layout.text);
    try t.expectEqualStrings("", shaped.lines.items[3].layout.text);
    try t.expectEqualStrings("e\u{301}x", shaped.lines.items[4].layout.text);
    try t.expectEqual(@as(f32, 60), shaped.size.height);
    const narrow = try service.layoutText(t.allocator, "e\u{301}x", 10, &.{.{ .len = "e\u{301}x".len, .font_id = font }}, 0, null);
    defer narrow.destroy();
    try t.expectEqual(@as(usize, 2), narrow.lines.items.len);
    try t.expectEqualStrings("e\u{301}", narrow.lines.items[0].layout.text);
}

/// A cached text view that relies on inherited style, useful for cache-key tests.
const Label = struct {
    renders: *usize,
    pub fn render(self: *const Label, f: *ui.Frame, _: *ui.Context(Label)) !ui.AnyElement {
        self.renders.* += 1;
        const content = try f.text("abc def ghi", .{
            .wrap = true,
            .id = 9,
            .runs = &.{ .{ .len = 4, .color = .{ .r = 1 } }, .{ .len = 7, .font = .{ .weight = .bold }, .color = .{ .g = 1 } } },
        });
        return f.div(.{ .style = .{ .width = .{ .percent = 100 }, .direction = .column }, .children = &.{content} });
    }
};
/// Parent can change inherited text style without notifying its cached child.
const Host = struct {
    label: ui.Entity(Label),
    font_size: f32 = 10,
    pub fn render(self: *const Host, f: *ui.Frame, _: *ui.Context(Host)) !ui.AnyElement {
        return f.div(.{ .text_style = .{ .font_size = self.font_size }, .children = &.{
            try f.cachedView(self.label, .{ .style = .{ .width = .{ .px = 30 }, .height = .{ .px = 100 }, .clip = true } }),
        } });
    }
    fn notify(_: *Host, cx: *ui.Context(Host)) !void {
        try cx.notify();
    }
    fn resizeText(self: *Host, cx: *ui.Context(Host)) !void {
        self.font_size = 20;
        try cx.notify();
    }
};
test "Yoga text measurement and cached glyph replay retain services and inherited styles" {
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const service = try stub(t.allocator);
    defer service.release();
    app.setTextSystem(service);
    var renders: usize = 0;
    const label = try app.create(Label{ .renders = &renders });
    const root = try app.create(Host{ .label = label });
    var window = try ui.Window.init(&app, root, .{ .width = 200, .height = 150 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 11), window.renderer.backend.scene.primitives.items.len);
    const first = window.renderer.backend.scene.primitives.items[0].glyph;
    try t.expectEqual(@as(f32, 10), first.font_size);
    try t.expectEqual(@as(f32, 1), first.color.r);
    try t.expectEqual(@as(f32, 1), window.renderer.backend.scene.primitives.items[4].glyph.color.g);
    try t.expectEqual(@as(f32, 30), window.hitboxes.items[0].bounds.size.height);
    const shape_calls = service.shape_calls;
    for (0..3) |_| {
        try root.update(Host.notify);
        _ = try window.drawIfNeeded();
    }
    try t.expectEqual(@as(usize, 1), renders);
    try t.expectEqual(shape_calls, service.shape_calls);
    try t.expectEqual(@as(?u64, 9), window.hitTest(.{ .x = 2, .y = 2 }));
    try root.update(Host.resizeText);
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 2), renders);
    try t.expectEqual(@as(f32, 20), window.renderer.backend.scene.primitives.items[0].glyph.font_size);
    const replacement = try stub(t.allocator);
    defer replacement.release();
    app.setTextSystem(replacement);
    try t.expect(window.needsDraw());
    _ = try window.drawIfNeeded();
    try t.expectEqual(@as(usize, 3), renders);
    try t.expect(window.renderer.backend.scene.primitives.items[0].glyph.system == replacement);
    replacement.clearCache();
    try t.expect(window.needsDraw());
    _ = try window.drawIfNeeded();
}

test "glyph atlas uses full font/size/scale/subpixel keys and grows across pages" {
    const Atlas = @import("renderer/atlas.zig").Atlas;
    const Key = @import("renderer/atlas.zig").Key;
    const service = try stub(t.allocator);
    defer service.release();
    const regular = try service.fontId(.{});
    const bold = try service.fontId(.{ .weight = .bold });
    var atlas = Atlas.init(t.allocator);
    defer atlas.deinit();
    atlas.page_side = 32;
    var glyph = @import("scene.zig").Glyph{ .system = service, .font_id = regular, .glyph_id = 'a', .font_size = 12, .position = .{}, .color = .{}, .clip = .{ .size = .{ .width = 100, .height = 100 } } };
    const first = try atlas.ensure(Key.init(glyph, 1));
    try t.expectEqualDeep(first, try atlas.ensure(Key.init(glyph, 1)));
    glyph.font_id = bold;
    _ = try atlas.ensure(Key.init(glyph, 1));
    glyph.position.x = 0.25;
    _ = try atlas.ensure(Key.init(glyph, 1));
    _ = try atlas.ensure(Key.init(glyph, 2));
    for (0..20) |i| {
        glyph.glyph_id = @intCast('b' + i);
        _ = try atlas.ensure(Key.init(glyph, 1));
    }
    try t.expect(atlas.pages.items.len > 1);
    try t.expectEqual(@as(u32, 24), atlas.entries.count());
    atlas.clear();
    try t.expectEqual(@as(u32, 0), atlas.entries.count());
}

fn allocations(a: std.mem.Allocator) !void {
    var app = ui.App.init(a);
    defer app.deinit();
    const service = try stub(a);
    defer service.release();
    service.cache_capacity = 2;
    app.setTextSystem(service);
    var renders: usize = 0;
    const label = try app.create(Label{ .renders = &renders });
    const root = try app.create(Host{ .label = label });
    var window = try ui.Window.init(&app, root, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    try root.update(Host.notify);
    _ = try window.drawIfNeeded();
    try root.update(Host.resizeText);
    _ = try window.drawIfNeeded();
    var atlas = @import("renderer/atlas.zig").Atlas.init(a);
    defer atlas.deinit();
    for (window.renderer.backend.scene.primitives.items) |primitive| if (primitive == .glyph) {
        _ = try atlas.ensure(@import("renderer/atlas.zig").Key.init(primitive.glyph, 1));
    };
}
test "text shaping, Yoga callbacks, cache replay and raster atlas clean up on allocation failures" {
    try t.checkAllAllocationFailures(t.allocator, allocations, .{});
}

test "a shaping failure during Yoga measurement preserves the committed glyph snapshot and retries" {
    // Replaces one vtable operation while retaining the real test backend's ownership.
    const Failure = struct {
        fn shape(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: f32, _: []const ts.FontRun) !*ts.LineLayout {
            return error.InjectedShapingFailure;
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const service = try stub(t.allocator);
    defer service.release();
    app.setTextSystem(service);
    var renders: usize = 0;
    const label = try app.create(Label{ .renders = &renders });
    const root = try app.create(Host{ .label = label });
    var window = try ui.Window.init(&app, root, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    const before = window.inspect().?;
    const old_vtable = service.platform.vtable;
    var failing = old_vtable.*;
    failing.layout_line = Failure.shape;
    service.platform.vtable = &failing;
    defer service.platform.vtable = old_vtable;
    service.clearCache();
    try t.expectError(error.InjectedShapingFailure, window.drawIfNeeded());
    try t.expect(window.inspect().? == before and window.needsDraw());
    try t.expectEqual(@as(?u64, 9), window.hitTest(.{ .x = 2, .y = 2 }));
    try t.expectEqual(@as(usize, 11), window.renderer.backend.scene.primitives.items.len);
    service.platform.vtable = old_vtable;
    _ = try window.drawIfNeeded();
    try t.expect(window.inspect().? != before and !window.needsDraw());
}

test "text honors box padding and background, and hidden text needs no text service" {
    // Exercises the same box-style options in both hidden and measured text paths.
    const Box = struct {
        hidden: bool,
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            return f.text("a", .{ .style = .{ .font_size = 10 }, .layout_style = .{ .hidden = self.hidden, .width = .{ .px = 30 }, .height = .{ .px = 20 }, .padding = .{ .left = 5, .top = 3 }, .background = .{ .b = 1 }, .clip = true } });
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const hidden = try app.create(Box{ .hidden = true });
    var invisible = try ui.Window.init(&app, hidden, .{ .width = 100, .height = 100 }, 1);
    defer invisible.deinit();
    _ = try invisible.drawIfNeeded();
    try t.expectEqual(@as(usize, 0), invisible.renderer.backend.scene.primitives.items.len);
    const service = try stub(t.allocator);
    defer service.release();
    app.setTextSystem(service);
    const visible = try app.create(Box{ .hidden = false });
    var window = try ui.Window.init(&app, visible, invisible.size, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    const primitives = window.renderer.backend.scene.primitives.items;
    try t.expectEqual(@as(usize, 2), primitives.len);
    try t.expectEqual(@as(f32, 30), primitives[0].quad.bounds.size.width);
    try t.expectEqual(@as(f32, 5), primitives[1].glyph.position.x);
    try t.expectEqual(@as(f32, 11), primitives[1].glyph.position.y);
}

test "owned glyph scenes keep their text service alive independently of the original owner" {
    var scene: ui.scene.Scene = .{};
    defer scene.deinit(t.allocator);
    {
        const service = try stub(t.allocator);
        defer service.release();
        const font = try service.fontId(.{});
        try scene.glyph(t.allocator, .{ .system = service, .font_id = font, .glyph_id = 'A', .font_size = 10, .position = .{}, .color = .{}, .clip = .{ .size = .{ .width = 100, .height = 100 } } });
    }
    var copy: ui.scene.Scene = .{};
    defer copy.deinit(t.allocator);
    try copy.appendPrimitives(t.allocator, scene.primitives.items);
    scene.deinit(t.allocator);
    scene = .{};
    const glyph = copy.primitives.items[0].glyph;
    var bitmap = try glyph.system.rasterizeGlyph(t.allocator, .{ .font_id = glyph.font_id, .glyph_id = glyph.glyph_id, .font_size = 10, .scale = 1 });
    defer bitmap.deinit(t.allocator);
    try t.expect(bitmap.pixels.len > 0);
}

test "color-only spans share shaping while original styled-run boundaries stay validated" {
    // The same font/text gets a new color split without changing its shape key.
    const Colors = struct {
        split: bool = false,
        invalid: bool = false,
        pub fn render(self: *const @This(), f: *ui.Frame, _: *ui.Context(@This())) !ui.AnyElement {
            if (self.invalid) return f.text("é", .{ .runs = &.{ .{ .len = 1 }, .{ .len = 1 } } });
            return f.text("abc", .{ .runs = if (self.split) &.{ .{ .len = 1, .color = .{ .r = 1 } }, .{ .len = 2, .color = .{ .g = 1 } } } else &.{} });
        }
        fn change(self: *@This(), cx: *ui.Context(@This())) !void {
            self.split = true;
            try cx.notify();
        }
    };
    var app = ui.App.init(t.allocator);
    defer app.deinit();
    const service = try stub(t.allocator);
    defer service.release();
    app.setTextSystem(service);
    const root = try app.create(Colors{});
    var window = try ui.Window.init(&app, root, .{ .width = 100, .height = 100 }, 1);
    defer window.deinit();
    _ = try window.drawIfNeeded();
    const shaped = service.shape_calls;
    try root.update(Colors.change);
    _ = try window.drawIfNeeded();
    try t.expectEqual(shaped, service.shape_calls);
    try t.expectEqual(@as(f32, 1), window.renderer.backend.scene.primitives.items[1].glyph.color.g);
    const invalid = try app.create(Colors{ .invalid = true });
    var bad = try ui.Window.init(&app, invalid, window.size, 1);
    defer bad.deinit();
    try t.expectError(error.InvalidTextRuns, bad.drawIfNeeded());
}

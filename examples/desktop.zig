const std = @import("std");
const ui = @import("zigui");
/// Subscription event carrying the latest pointer position, or null on exit.
const CursorChanged = struct { position: ?ui.geometry.Point };
/// Focused action that grows the cursor-following quad.
const Increment = struct {};
/// Workspace action that changes the shared palette used by both cached views.
const TogglePalette = struct {};
/// External instrumentation for observing renders without adding reactive dependencies.
const Stats = struct { counter: usize = 0, sidebar: usize = 0 };
/// Shared reactive color choice: notifying this entity invalidates both readers.
const Palette = struct {
    warm: bool = false,
    fn toggle(self: *Palette, cx: *ui.Context(Palette)) !void {
        self.warm = !self.warm;
        try cx.notify();
    }
};
/// Interactive cached view whose own state tracks the quad's size and position.
/// It reads the shared palette and owns the focused increment/input handlers.
const Counter = struct {
    value: u32 = 1,
    cursor: ?ui.geometry.Point = null,
    palette: ui.Entity(Palette),
    focus: ui.FocusHandle,
    stats: *Stats,
    pub fn render(self: *const Counter, f: *ui.Frame, cx: *ui.Context(Counter)) !ui.AnyElement {
        self.stats.counter += 1;
        const palette = try self.palette.read();
        const position = self.cursor orelse ui.geometry.Point{ .x = 24, .y = 24 };
        const label = try f.text(try std.fmt.allocPrint(f.allocator(), "{d}", .{self.value}), .{ .style = .{ .font_size = 20, .font = .{ .family = "Menlo", .weight = .bold } } });
        const bar = try f.div(.{ .id = 1, .children = &.{label}, .style = .{ .absolute = true, .left = position.x, .top = position.y, .width = .{ .px = @as(f32, @floatFromInt(self.value)) * 40 }, .height = .{ .px = 60 }, .padding = .{ .left = 8, .top = 8 }, .border_widths = .all(2), .corner_radii = .all(10), .border_color = .{ .r = 1, .g = 1, .b = 1, .a = 0.8 }, .background = if (palette.warm) .{ .r = 0.9, .g = 0.3, .b = 0.1 } else .{ .r = 0.1, .g = 0.5, .b = 0.9 } } });
        return f.div(.{
            .style = .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .clip = true },
            .children = &.{bar},
            .focus = self.focus,
            .key_context = "Counter",
            .listeners = &.{ try f.entityActionListener(cx.entity, Increment, onIncrement), try f.entityInputListener(cx.entity, onInput) },
            .bindings = &.{try f.bindKey("space", .{}, "Counter", Increment{})},
        });
    }
    fn trackCursor(_: *Counter, cx: *ui.Context(Counter)) !void {
        var subscription = try cx.subscribe(cx.entity, CursorChanged, void, {}, cursorChanged);
        subscription.detach();
    }
    fn cursorChanged(self: *Counter, _: ui.Entity(Counter), event: *const CursorChanged, _: *void, cx: *ui.Context(Counter)) void {
        if (std.meta.eql(self.cursor, event.position)) return;
        self.cursor = event.position;
        cx.notify() catch |err| std.log.err("cursor update: {s}", .{@errorName(err)});
    }
    fn increment(self: *Counter, cx: *ui.Context(Counter)) !void {
        self.value = self.value % 12 + 1;
        try cx.notify();
    }
    fn onIncrement(self: *Counter, _: *const Increment, phase: ui.DispatchPhase, cx: *ui.Context(Counter), ec: *ui.EventContext) !void {
        if (phase != .bubble) return;
        try self.increment(cx);
        ec.stopPropagation();
    }
    fn onInput(self: *Counter, event: ui.input.PlatformInput, phase: ui.DispatchPhase, cx: *ui.Context(Counter), ec: *ui.EventContext) !void {
        if (phase != .bubble or event != .mouse_down or event.mouse_down.button != .left) return;
        self.cursor = event.mouse_down.position;
        try self.increment(cx);
        try ec.focus(self.focus);
        ec.stopPropagation();
    }
};
/// Cached sibling that reads only the palette, so pointer movement can reuse it.
const Sidebar = struct {
    palette: ui.Entity(Palette),
    stats: *Stats,
    pub fn render(self: *const Sidebar, f: *ui.Frame, _: *ui.Context(Sidebar)) !ui.AnyElement {
        self.stats.sidebar += 1;
        const palette = try self.palette.read();
        return f.div(.{ .id = 2, .children = &.{try f.text("idle", .{})}, .style = .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 }, .justify = .center, .align_items = .center, .background = if (palette.warm) .{ .r = 0.3, .g = 0.08, .b = 0.02 } else .{ .r = 0.02, .g = 0.15, .b = 0.3 } } });
    }
};
/// Cached typography sample exercising styled runs, wrapping, fallback fonts,
/// combining marks, RTL shaping and color glyphs through the same text interface.
const Typography = struct {
    pub fn render(_: *const Typography, f: *ui.Frame, _: *ui.Context(Typography)) !ui.AnyElement {
        const title = "CoreText → Metal\n";
        const sample = "café · e\u{301} · 👩‍💻 · 你好\nשלום · العربية\nResize to wrap this text. Space grows the quad; T changes the shared palette.";
        return f.text(title ++ sample, .{ .wrap = true, .style = .{ .font = .{ .family = "Helvetica" }, .font_size = 22, .line_height = 30 }, .runs = &.{
            .{ .len = title.len, .font = .{ .family = "Helvetica", .weight = .bold }, .color = .{ .r = 0.2, .g = 0.7, .b = 1 } },
            .{ .len = sample.len },
        } });
    }
};
/// Uncached parent that arranges the two cache boundaries and handles the shared
/// palette action as it bubbles up from the focused counter.
const Workspace = struct {
    counter: ui.Entity(Counter),
    sidebar: ui.Entity(Sidebar),
    typography: ui.Entity(Typography),
    palette: ui.Entity(Palette),
    pub fn render(self: *const Workspace, f: *ui.Frame, cx: *ui.Context(Workspace)) !ui.AnyElement {
        const sidebar = try f.cachedView(self.sidebar, .{ .style = .{ .absolute = true, .left = 24, .top = 120, .width = .{ .px = 50 }, .height = .{ .px = 40 }, .border_widths = .all(1), .border_color = .{ .r = 0.3, .g = 0.6, .b = 0.8 } } });
        const counter = try f.cachedView(self.counter, .{ .style = .{ .width = .{ .percent = 100 }, .height = .{ .percent = 100 } } });
        const typography = try f.cachedView(self.typography, .{ .style = .{ .absolute = true, .left = 24, .top = 180, .width = .{ .percent = 80 }, .height = .{ .px = 220 }, .clip = true, .padding = .all(8), .border_widths = .{ .left = 3, .top = 1, .right = 1, .bottom = 1 }, .corner_radii = .{ .top_left = 14, .top_right = 14, .bottom_left = 6, .bottom_right = 6 }, .border_color = .{ .r = 0.2, .g = 0.5, .b = 0.8 } } });
        return f.div(.{
            .children = &.{ sidebar, typography, counter },
            .key_context = "Workspace",
            .listeners = &.{try f.entityActionListener(cx.entity, TogglePalette, toggle)},
            .bindings = &.{try f.bindKey("t", .{}, "Workspace", TogglePalette{})},
        });
    }
    fn toggle(self: *Workspace, _: *const TogglePalette, phase: ui.DispatchPhase, cx: *ui.Context(Workspace), ec: *ui.EventContext) !void {
        if (phase != .bubble) return;
        try cx.app.update(self.palette, Palette.toggle);
        ec.stopPropagation();
    }
};
/// Window-level fallback for unhandled pointer updates and application shortcuts.
/// It feeds cursor events into the counter's subscription independently of focus.
const Controller = struct {
    counter: ui.Entity(Counter),
    platform: *ui.Platform,
    fn dispatch(ptr: *anyopaque, event: ui.input.PlatformInput, target: ?u64) ui.input.DispatchEventResult {
        const self: *Controller = @ptrCast(@alignCast(ptr));
        if (event == .mouse_exit or event.position() != null) {
            self.counter.app.emit(self.counter, CursorChanged{ .position = if (event == .mouse_exit) null else event.position() }) catch |err| std.log.err("cursor event: {s}", .{@errorName(err)});
        }
        const increment = switch (event) {
            .mouse_down => |e| target == 1 and e.button == .left,
            .key_down => |e| blk: {
                if (e.modifiers.command and std.mem.eql(u8, e.key, "q")) {
                    self.platform.quit();
                    return .{ .handled = true };
                }
                break :blk false;
            },
            else => false,
        };
        if (increment) self.counter.update(Counter.increment) catch |err| std.log.err("update: {s}", .{@errorName(err)});
        return .{ .handled = increment };
    }
};
pub fn main(init: std.process.Init) !void {
    var stats: Stats = .{};
    var app = ui.App.init(std.heap.c_allocator);
    defer app.deinit();
    var platform = try ui.Platform.init(app.allocator);
    defer platform.deinit();
    app.wakeup = .{ .context = &platform, .schedule = ui.Platform.schedule };
    defer app.wakeup = null;
    const palette = try app.create(Palette{});
    const focus = app.newFocusHandle();
    const counter = try app.create(Counter{ .palette = palette, .focus = focus, .stats = &stats });
    const sidebar = try app.create(Sidebar{ .palette = palette, .stats = &stats });
    const typography = try app.create(Typography{});
    const root = try app.create(Workspace{ .counter = counter, .sidebar = sidebar, .palette = palette, .typography = typography });
    try counter.update(Counter.trackCursor);
    const window = try ui.NativeWindow.create(&app, platform, root, .{ .title = "zigui — move pointer; Space increments; T changes both colors" });
    defer window.destroy();
    var controller = Controller{ .counter = counter, .platform = &platform };
    window.on_input = .{ .context = &controller, .dispatch = Controller.dispatch };
    _ = try window.content.drawIfNeeded();
    try window.content.focus(focus);
    _ = try window.content.drawIfNeeded();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--smoke")) {
        const previous = stats;
        _ = Controller.dispatch(&controller, .{ .mouse_move = .{ .position = .{ .x = 60, .y = 70 } } }, null);
        _ = try window.content.drawIfNeeded();
        std.debug.assert(stats.counter == previous.counter + 1 and stats.sidebar == previous.sidebar);
        std.debug.assert(window.content.hitTest(.{ .x = 60, .y = 70 }) == 1);
        _ = try window.content.dispatchInput(.{ .key_down = .{ .key_code = 49, .key = "space", .modifiers = .{} } });
        _ = try window.content.drawIfNeeded();
        std.debug.assert((try counter.read()).value == 2 and stats.sidebar == previous.sidebar);
        _ = try window.content.dispatchAction(TogglePalette{});
        _ = try window.content.drawIfNeeded();
        std.debug.assert(stats.sidebar == previous.sidebar + 1);
        var glyphs: usize = 0;
        for (window.content.inspect().?.scene) |primitive| if (primitive == .glyph) {
            glyphs += 1;
        };
        std.debug.assert(glyphs > 30);
        std.debug.print("Metal/text/cache smoke passed: {d} glyphs, cursor quad, cached sidebar, focused action and shared palette\n", .{glyphs});
        return;
    }
    platform.run();
    std.debug.print("view renders — counter: {d}, sidebar: {d}; last frame cache hits: {d}\n", .{ stats.counter, stats.sidebar, window.content.inspect().?.cache_hits });

    if (window.last_error) |err| return err;
}

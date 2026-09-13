const reactive = @import("app.zig");
const elements = @import("element.zig");
const Frame = @import("frame.zig").Frame;
const layout = @import("layout.zig");
const g = @import("geometry.zig");
const state = @import("view_state.zig");

/// Opt-in cache boundary configuration. The style supplies outer layout without
/// measuring cached contents; key disambiguates repeated sibling entity views.
pub const CachedViewOptions = struct { style: layout.Style, key: u64 = 0 };

pub fn create(f: *Frame, entity: anytype, key: u64, style: ?layout.Style) !elements.AnyElement {
    if (entity.app != f.app) return error.WrongApp;
    // Recovers the concrete entity type behind ViewElement's erased render
    // function, reading it through the normal dependency-tracking API.
    const Adapter = struct {
        fn render(frame: *Frame, id: reactive.EntityId) !elements.AnyElement {
            const handle = @TypeOf(entity){ .app = frame.app, .id = id };
            const value = try handle.read();
            var cx = reactive.Context(@TypeOf(entity).Value){ .app = frame.app, .entity = handle };
            return value.render(frame, &cx);
        }
    };
    return f.element(ViewElement{ .entity = entity.id, .key = key, .style = style, .render = Adapter.render });
}

/// Temporary element that establishes an owning view scope around every phase.
/// Ordinary views render during layout requests; cached views first lay out an
/// outer boundary, then render or replay their contents once bounds are known.
/// Persistent cache metadata lives in Snapshot, not in this frame-arena value.
const ViewElement = struct {
    pub const RequestLayoutState = ?elements.AnyElement;
    pub const PrepaintState = g.Bounds;
    entity: reactive.EntityId,
    key: u64,
    style: ?layout.Style,
    render: *const fn (*Frame, reactive.EntityId) anyerror!elements.AnyElement,
    view_id: usize = undefined,
    local_origin: g.Point = .{},
    old_cache: ?state.Cache = null,

    fn renderContents(self: *ViewElement, f: *Frame) !elements.AnyElement {
        const old_phase = f.phase;
        f.phase = .render;
        defer f.phase = old_phase;
        return self.render(f, self.entity);
    }
    pub fn requestLayout(self: *ViewElement, f: *Frame) !elements.LayoutRequest(RequestLayoutState) {
        self.view_id = try f.addView(self.entity, self.key);
        const old_view = f.active_view;
        f.active_view = self.view_id;
        defer f.active_view = old_view;
        try f.app.track(self.entity);
        if (self.style) |style| return .{ .id = try f.layout.request(style, &.{}), .state = null };
        const child = try self.renderContents(f);
        return .{ .id = try child.requestLayout(f), .state = child };
    }
    pub fn prepaint(self: *ViewElement, f: *Frame, bounds: g.Bounds, child: *RequestLayoutState) !g.Bounds {
        const old_view = f.active_view;
        f.active_view = self.view_id;
        defer f.active_view = old_view;
        f.snapshot.views.items[self.view_id].dispatch_node = f.active_node;
        f.snapshot.tree.nodes.items[f.active_node.?].view = self.view_id;
        const old_clip = f.clip;
        defer f.clip = old_clip;
        const style = self.style orelse {
            try child.*.?.prepaint(f);
            return old_clip;
        };
        if (style.hidden) return old_clip;
        if (style.clip) f.clip = bounds.inset(try style.borderWidths(f.scale)).intersect(f.clip);
        var text_style = f.text_style;
        text_style.font.family = try f.snapshot.memory().dupe(u8, text_style.font.family);
        const key = state.CacheKey{ .bounds = bounds, .clip = old_clip, .viewport = f.size, .scale = f.scale, .style = style, .text_style = text_style };
        const view = f.snapshot.views.items[self.view_id];
        const node_start = f.snapshot.tree.nodes.items.len;
        const hit_start = f.hitboxes.items.len;
        if (view.previous) |previous| {
            if (view.dirty_reason == .clean) {
                if (f.previous.?.views.items[previous].cache) |cache| {
                    if (key.eql(cache.key)) {
                        self.old_cache = cache;
                        try f.reusePrepaint(self.view_id, cache);
                    } else {
                        f.snapshot.views.items[self.view_id].dirty_reason = .geometry;
                    }
                }
            }
        }
        if (self.old_cache == null) {
            f.snapshot.cache_misses += 1;
            child.* = try self.renderContents(f);
            const old_phase = f.phase;
            defer f.phase = old_phase;
            self.local_origin = bounds.origin;
            f.phase = .request_layout;
            const id = try child.*.?.requestLayout(f);
            // A detached containing node reproduces the boundary's flex rules:
            // the rendered root is still a child and must shrink/align normally.
            const container = try f.layout.request(.{
                .width = .{ .px = bounds.size.width },
                .height = .{ .px = bounds.size.height },
                .padding = style.padding,
                .border_widths = style.border_widths,
                .direction = style.direction,
                .align_items = style.align_items,
                .justify = style.justify,
                .wrap = style.wrap,
            }, &.{id});
            f.phase = .compute_layout;
            f.layout.compute(container, bounds.size);
            if (f.layout.measure_error) |err| return err;
            f.phase = .prepaint;
            const offset = f.layout.offset;
            f.layout.offset = self.local_origin;
            defer f.layout.offset = offset;
            try child.*.?.prepaint(f);
        }
        f.snapshot.views.items[self.view_id].cache = .{
            .key = key,
            .nodes = .{ .start = node_start, .end = f.snapshot.tree.nodes.items.len },
            .hitboxes = .{ .start = hit_start, .end = f.hitboxes.items.len },
            .scene = .{ .start = 0, .end = 0 },
        };
        return old_clip;
    }
    pub fn paint(self: *ViewElement, f: *Frame, bounds: g.Bounds, child: *RequestLayoutState, clip: *g.Bounds) !void {
        const old_view = f.active_view;
        f.active_view = self.view_id;
        defer f.active_view = old_view;
        const old_clip = f.clip;
        f.clip = clip.*;
        defer f.clip = old_clip;
        const style = self.style orelse {
            try child.*.?.paint(f);
            return;
        };
        if (style.hidden) return;
        const start = f.scene.primitives.items.len;
        if (self.old_cache) |cache| {
            try f.reusePaint(self.view_id, cache);
        } else {
            const borders = try style.borderWidths(f.scale);
            try f.scene.box(f.allocator(), .{ .bounds = bounds, .color = style.background orelse .{ .a = 0 }, .clip = clip.*, .corner_radii = style.corner_radii, .border_widths = borders, .border_color = style.border_color orelse .{ .a = 0 } });
            if (style.clip) f.clip = bounds.inset(borders).intersect(clip.*);
            const offset = f.layout.offset;
            f.layout.offset = self.local_origin;
            defer f.layout.offset = offset;
            try child.*.?.paint(f);
        }
        f.snapshot.views.items[self.view_id].cache.?.scene = .{ .start = start, .end = f.scene.primitives.items.len };
        f.snapshot.views.items[self.view_id].cache.?.painted = true;
    }
};

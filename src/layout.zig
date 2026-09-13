const std = @import("std");
const g = @import("geometry.zig");
pub const c = @cImport({
    @cInclude("yoga/Yoga.h");
});
pub const LayoutId = *c.YGNode;
pub const Length = union(enum) { auto, px: f32, percent: f32 };
pub const Direction = enum { row, column, row_reverse, column_reverse };
pub const Align = enum { start, center, end, stretch, baseline };
pub const Justify = enum { start, center, end, space_between, space_around, space_evenly };
pub const Edges = struct { left: f32 = 0, top: f32 = 0, right: f32 = 0, bottom: f32 = 0 };
pub const Style = struct {
    width: Length = .auto,
    height: Length = .auto,
    min_width: ?f32 = null,
    min_height: ?f32 = null,
    max_width: ?f32 = null,
    max_height: ?f32 = null,
    direction: Direction = .row,
    grow: f32 = 0,
    shrink: f32 = 1,
    basis: Length = .auto,
    wrap: bool = false,
    align_items: Align = .stretch,
    justify: Justify = .start,
    gap: f32 = 0,
    padding: Edges = .{},
    margin: Edges = .{},
    absolute: bool = false,
    left: ?f32 = null,
    top: ?f32 = null,
    hidden: bool = false,
    clip: bool = false,
    background: ?g.Color = null,
};

/// Owns all Yoga nodes for one frame, including partially constructed trees.
pub const Layout = struct {
    allocator: std.mem.Allocator,
    config: *c.YGConfig,
    nodes: std.ArrayList(LayoutId) = .empty,

    pub fn init(allocator: std.mem.Allocator, scale: f32) !Layout {
        if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidScale;
        const config = c.YGConfigNew() orelse return error.OutOfMemory;
        c.YGConfigSetUseWebDefaults(config, true);
        c.YGConfigSetPointScaleFactor(config, scale);
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Layout) void {
        // Non-recursive free detaches children; each node is freed exactly once.
        for (self.nodes.items) |node| c.YGNodeFree(node);
        self.nodes.deinit(self.allocator);
        c.YGConfigFree(self.config);
    }

    pub fn request(self: *Layout, style: Style, children: []const LayoutId) !LayoutId {
        const node = c.YGNodeNewWithConfig(self.config) orelse return error.OutOfMemory;
        errdefer c.YGNodeFree(node);
        try self.nodes.append(self.allocator, node);
        apply(node, style);
        for (children, 0..) |child, i| c.YGNodeInsertChild(node, child, @intCast(i));
        return node;
    }

    pub fn compute(_: *Layout, root: LayoutId, size: g.Size) void {
        c.YGNodeCalculateLayout(root, size.width, size.height, c.YGDirectionLTR);
    }

    pub fn bounds(_: *const Layout, node: LayoutId) g.Bounds {
        var origin = g.Point{ .x = c.YGNodeLayoutGetLeft(node), .y = c.YGNodeLayoutGetTop(node) };
        var parent = c.YGNodeGetOwner(node);
        while (parent) |p| : (parent = c.YGNodeGetOwner(p)) {
            origin.x += c.YGNodeLayoutGetLeft(p);
            origin.y += c.YGNodeLayoutGetTop(p);
        }
        return .{ .origin = origin, .size = .{ .width = c.YGNodeLayoutGetWidth(node), .height = c.YGNodeLayoutGetHeight(node) } };
    }
};

fn dimension(node: LayoutId, comptime name: []const u8, value: Length) void {
    switch (value) {
        .auto => @field(c, "YGNodeStyleSet" ++ name ++ "Auto")(node),
        .px => |v| @field(c, "YGNodeStyleSet" ++ name)(node, v),
        .percent => |v| @field(c, "YGNodeStyleSet" ++ name ++ "Percent")(node, v),
    }
}

fn apply(node: LayoutId, s: Style) void {
    dimension(node, "Width", s.width);
    dimension(node, "Height", s.height);
    dimension(node, "FlexBasis", s.basis);
    if (s.min_width) |v| c.YGNodeStyleSetMinWidth(node, v);
    if (s.min_height) |v| c.YGNodeStyleSetMinHeight(node, v);
    if (s.max_width) |v| c.YGNodeStyleSetMaxWidth(node, v);
    if (s.max_height) |v| c.YGNodeStyleSetMaxHeight(node, v);
    c.YGNodeStyleSetFlexDirection(node, switch (s.direction) {
        .row => c.YGFlexDirectionRow,
        .column => c.YGFlexDirectionColumn,
        .row_reverse => c.YGFlexDirectionRowReverse,
        .column_reverse => c.YGFlexDirectionColumnReverse,
    });
    c.YGNodeStyleSetFlexGrow(node, s.grow);
    c.YGNodeStyleSetFlexShrink(node, s.shrink);
    c.YGNodeStyleSetFlexWrap(node, if (s.wrap) c.YGWrapWrap else c.YGWrapNoWrap);
    c.YGNodeStyleSetAlignItems(node, switch (s.align_items) {
        .start => c.YGAlignFlexStart,
        .center => c.YGAlignCenter,
        .end => c.YGAlignFlexEnd,
        .stretch => c.YGAlignStretch,
        .baseline => c.YGAlignBaseline,
    });
    c.YGNodeStyleSetJustifyContent(node, switch (s.justify) {
        .start => c.YGJustifyFlexStart,
        .center => c.YGJustifyCenter,
        .end => c.YGJustifyFlexEnd,
        .space_between => c.YGJustifySpaceBetween,
        .space_around => c.YGJustifySpaceAround,
        .space_evenly => c.YGJustifySpaceEvenly,
    });
    c.YGNodeStyleSetGap(node, c.YGGutterAll, s.gap);
    inline for (.{ "left", "top", "right", "bottom" }, .{ c.YGEdgeLeft, c.YGEdgeTop, c.YGEdgeRight, c.YGEdgeBottom }) |name, edge| {
        c.YGNodeStyleSetPadding(node, edge, @field(s.padding, name));
        c.YGNodeStyleSetMargin(node, edge, @field(s.margin, name));
    }
    c.YGNodeStyleSetPositionType(node, if (s.absolute) c.YGPositionTypeAbsolute else c.YGPositionTypeRelative);
    if (s.left) |v| c.YGNodeStyleSetPosition(node, c.YGEdgeLeft, v);
    if (s.top) |v| c.YGNodeStyleSetPosition(node, c.YGEdgeTop, v);
    c.YGNodeStyleSetDisplay(node, if (s.hidden) c.YGDisplayNone else c.YGDisplayFlex);
}

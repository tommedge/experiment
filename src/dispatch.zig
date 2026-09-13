const std = @import("std");
const reactive = @import("app.zig");
const input = @import("input.zig");

pub const Phase = enum { capture, bubble };
pub const FocusHandle = struct { app: *reactive.App, id: u64 };
pub const NodeId = usize;

/// Owned callback/action capture. Copies of this handle must retain.
/// Capture values transfer ownership on successful creation; referenced memory
/// must outlive the capture. Prefer entity handles over pointers into a frame.
pub const Payload = struct {
    allocator: std.mem.Allocator,
    references: usize = 1,
    ptr: *anyopaque,
    type_name: []const u8,
    destroy: *const fn (*Payload) void,

    pub fn create(a: std.mem.Allocator, value: anytype) !*Payload {
        const T = @TypeOf(value);
        const Box = struct {
            header: Payload,
            value: T,
            fn destroy(header: *Payload) void {
                const self: *@This() = @fieldParentPtr("header", header);
                switch (@typeInfo(T)) {
                    .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(T, "deinit")) self.value.deinit(),
                    else => {},
                }
                header.allocator.destroy(self);
            }
        };
        const box = try a.create(Box);
        box.* = .{ .header = .{ .allocator = a, .ptr = &box.value, .type_name = @typeName(T), .destroy = Box.destroy }, .value = value };
        return &box.header;
    }
    pub fn retain(self: *Payload) *Payload {
        self.references += 1;
        return self;
    }
    pub fn release(self: *Payload) void {
        self.references -= 1;
        if (self.references == 0) self.destroy(self);
    }
};

pub const EventContext = struct {
    app: *reactive.App,
    focused: *?u64,
    tree: *const Tree,
    handled: bool = false,
    stopped: bool = false,
    pub fn handle(self: *EventContext) void {
        self.handled = true;
    }
    pub fn stopPropagation(self: *EventContext) void {
        self.handled = true;
        self.stopped = true;
    }
    pub fn focus(self: *EventContext, target: FocusHandle) !void {
        if (target.app != self.app) return error.WrongApp;
        if (self.tree.focusNode(target.id) == null) return error.FocusUnavailable;
        self.focused.* = target.id;
    }
    pub fn blur(self: *EventContext) void {
        self.focused.* = null;
    }
};

pub const Listener = struct {
    capture: *Payload,
    action_type: ?[]const u8 = null,
    invoke: *const fn (*anyopaque, ?input.PlatformInput, ?*const anyopaque, Phase, *EventContext) anyerror!void,
};
pub const Binding = struct {
    key: []const u8,
    modifiers: input.Modifiers = .{},
    context: ?[]const u8 = null,
    action: *Payload,
};
pub const Node = struct {
    parent: ?NodeId,
    view: ?usize = null,
    focus: ?u64 = null,
    context: ?[]const u8 = null,
    listeners: std.ArrayList(Listener) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    text_input: ?TextInput = null,
};
pub const TextInput = struct { capture: *Payload, handler: input.TextInputHandler };

pub const Tree = struct {
    nodes: std.ArrayList(Node) = .empty,
    focus_nodes: std.AutoHashMapUnmanaged(u64, NodeId) = .empty,

    pub fn focusNode(self: *const Tree, id: u64) ?NodeId {
        return self.focus_nodes.get(id);
    }
    pub fn registerFocus(self: *Tree, a: std.mem.Allocator, id: u64, node: NodeId) !void {
        const entry = try self.focus_nodes.getOrPut(a, id);
        if (entry.found_existing) return error.DuplicateFocusHandle;
        entry.value_ptr.* = node;
    }
    fn path(self: *const Tree, a: std.mem.Allocator, target: NodeId) !std.ArrayList(NodeId) {
        var result: std.ArrayList(NodeId) = .empty;
        errdefer result.deinit(a);
        var current: ?NodeId = target;
        while (current) |id| {
            try result.append(a, id);
            current = self.nodes.items[id].parent;
        }
        std.mem.reverse(NodeId, result.items);
        return result;
    }
    fn deliver(self: *const Tree, route: []const NodeId, event: ?input.PlatformInput, action: ?*Payload, cx: *EventContext) !void {
        inline for (.{ Phase.capture, Phase.bubble }) |phase| {
            for (0..route.len) |i| {
                const id = route[if (phase == .capture) i else route.len - i - 1];
                for (self.nodes.items[id].listeners.items) |listener| {
                    const matches = if (action) |value| if (listener.action_type) |name| std.mem.eql(u8, name, value.type_name) else false else listener.action_type == null;
                    if (matches) try listener.invoke(listener.capture.ptr, event, if (action) |value| value.ptr else null, phase, cx);
                    if (cx.stopped) return;
                }
            }
        }
    }
    pub fn dispatchAction(self: *const Tree, target: NodeId, action: *Payload, cx: *EventContext) !void {
        var route = try self.path(cx.app.allocator, target);
        defer route.deinit(cx.app.allocator);
        try self.deliver(route.items, null, action, cx);
    }
    pub fn dispatch(self: *const Tree, target: NodeId, event: input.PlatformInput, cx: *EventContext) !void {
        var route = try self.path(cx.app.allocator, target);
        defer route.deinit(cx.app.allocator);
        // Raw listeners can intercept keys before binding resolution.
        try self.deliver(route.items, event, null, cx);
        if (cx.handled or cx.stopped) return;
        if (event == .key_down) {
            const key = event.key_down;
            const Candidate = struct {
                binding: Binding,
                context_depth: usize,
                owner_depth: usize,
                registration: usize,
                fn less(_: void, a: @This(), b: @This()) bool {
                    if (a.context_depth != b.context_depth) return a.context_depth > b.context_depth;
                    if (a.owner_depth != b.owner_depth) return a.owner_depth > b.owner_depth;
                    return a.registration > b.registration;
                }
            };
            var candidates: std.ArrayList(Candidate) = .empty;
            defer candidates.deinit(cx.app.allocator);
            for (route.items, 0..) |id, depth| {
                for (self.nodes.items[id].bindings.items, 0..) |binding, registration| {
                    if (!std.mem.eql(u8, binding.key, key.key) or !std.meta.eql(binding.modifiers, key.modifiers)) continue;
                    var context_depth: usize = 0;
                    if (binding.context) |context| {
                        for (route.items, 0..) |ancestor, i| if (self.nodes.items[ancestor].context) |name| {
                            if (std.mem.eql(u8, name, context)) context_depth = i + 1;
                        };
                        if (context_depth == 0) continue;
                    }
                    try candidates.append(cx.app.allocator, .{ .binding = binding, .context_depth = context_depth, .owner_depth = depth, .registration = registration });
                }
            }
            std.mem.sort(Candidate, candidates.items, {}, Candidate.less);
            for (candidates.items) |candidate| {
                try self.deliver(route.items, null, candidate.binding.action, cx);
                if (cx.handled or cx.stopped) return;
            }
        }
    }
};

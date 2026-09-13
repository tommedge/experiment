const std = @import("std");
const Allocator = std.mem.Allocator;
pub const EntityId = usize;
pub const Dependency = struct { id: EntityId, revision: u64 };
/// Schedules a future host event-loop turn; must not run UI work inline.
pub const Wakeup = struct { context: *anyopaque, schedule: *const fn (*anyopaque) void };

pub fn Entity(comptime T: type) type {
    return struct {
        pub const Value = T;
        app: *App,
        id: EntityId,
        pub fn read(self: @This()) !*const T {
            return self.app.read(self);
        }
        pub fn update(self: @This(), callback: anytype) !void {
            try self.app.update(self, callback);
        }
        pub fn downgrade(self: @This()) WeakEntity(T) {
            return .{ .app = self.app, .id = self.id };
        }
    };
}

pub fn WeakEntity(comptime T: type) type {
    return struct {
        app: *App,
        id: EntityId,
        pub fn upgrade(self: @This()) ?Entity(T) {
            if (!self.app.alive(self.id)) return null;
            return .{ .app = self.app, .id = self.id };
        }
    };
}

pub fn Context(comptime T: type) type {
    return struct {
        app: *App,
        entity: Entity(T),
        pub fn notify(self: *@This()) !void {
            try self.app.notify(self.entity.id);
        }
        pub fn emit(self: *@This(), event: anytype) !void {
            try self.app.emit(self.entity, event);
        }

        pub fn observe(self: *@This(), source: anytype, comptime C: type, capture: C, comptime callback: anytype) !Subscription {
            const S = @TypeOf(source);
            const Wrapper = struct {
                owner: WeakEntity(T),
                capture: C,
                fn call(w: *@This(), emitter: S, app: *App) void {
                    const owner = w.owner.upgrade() orelse return;
                    const state = app.borrow(owner) catch return;
                    defer app.unborrow(owner.id);
                    var cx = Context(T){ .app = app, .entity = owner };
                    callback(state, emitter, &w.capture, &cx);
                }
            };
            const sub = try self.app.observe(source, Wrapper, .{ .owner = self.entity.downgrade(), .capture = capture }, Wrapper.call);
            self.app.listener(sub.id).?.owner = self.entity.id;
            return sub;
        }

        pub fn subscribe(self: *@This(), source: anytype, comptime E: type, comptime C: type, capture: C, comptime callback: anytype) !Subscription {
            const S = @TypeOf(source);
            const Wrapper = struct {
                owner: WeakEntity(T),
                capture: C,
                fn call(w: *@This(), emitter: S, event: *const E, app: *App) void {
                    const owner = w.owner.upgrade() orelse return;
                    const state = app.borrow(owner) catch return;
                    defer app.unborrow(owner.id);
                    var cx = Context(T){ .app = app, .entity = owner };
                    callback(state, emitter, event, &w.capture, &cx);
                }
            };
            const sub = try self.app.subscribe(source, E, Wrapper, .{ .owner = self.entity.downgrade(), .capture = capture }, Wrapper.call);
            self.app.listener(sub.id).?.owner = self.entity.id;
            return sub;
        }
    };
}

/// Move-only by convention. Use `defer subscription.deinit()` or detach().
/// The App must outlive every handle. Zig has no automatic destructors.
pub const Subscription = struct {
    app: *App,
    id: u64,
    pub fn deinit(self: *Subscription) void {
        if (self.app.listener(self.id)) |entry| entry.active = false;
        self.id = 0;
    }
    pub fn detach(self: *Subscription) void {
        self.id = 0;
    }
};

const Slot = struct {
    value: ?*anyopaque,
    type_name: []const u8,
    destroy: *const fn (Allocator, *anyopaque) void,
    borrowed: bool = false,
    pending_notify: bool = false,
    revision: u64 = 0,
};
const Listener = struct {
    id: u64,
    source: EntityId,
    owner: ?EntityId = null,
    event_type: ?[]const u8,
    active: bool = true,
    capture: *anyopaque,
    invoke: *const fn (*anyopaque, EntityId, ?*const anyopaque, *App) void,
    destroy: *const fn (Allocator, *anyopaque) void,
};
const Effect = struct {
    source: EntityId,
    event_type: ?[]const u8 = null,
    payload: ?*anyopaque = null,
    destroy: ?*const fn (Allocator, *anyopaque) void = null,
};

/// Single UI-thread runtime. Entities are App-owned, explicitly destroyed.
/// Stable, never-reused IDs make stale weak handles safe until App.deinit().
pub const App = struct {
    allocator: Allocator,
    slots: std.ArrayList(Slot) = .empty,
    listeners: std.ArrayList(Listener) = .empty,
    effects: std.ArrayList(Effect) = .empty,
    next_listener: u64 = 1,
    depth: usize = 0,
    flushing: bool = false,
    tracking: ?*std.ArrayList(Dependency) = null,
    /// Scoped bridge to the active frame's per-view dependency recorder. The
    /// erased context is borrowed only while the frame's traversal is active.
    view_tracking: ?struct { context: *anyopaque, record: *const fn (*anyopaque, Dependency) anyerror!void } = null,
    next_focus: u64 = 1,
    text_system: ?*@import("text_system.zig").TextSystem = null,
    text_revision: u64 = 0,
    wakeup: ?Wakeup = null,

    pub fn init(allocator: Allocator) App {
        return .{ .allocator = allocator };
    }
    /// Retains a generic text service. Existing scenes retain their original
    /// service until released; replacing this selection invalidates window caches.
    pub fn setTextSystem(self: *App, system: *@import("text_system.zig").TextSystem) void {
        if (self.text_system == system) return;
        _ = system.retain();
        if (self.text_system) |old| old.release();
        self.text_system = system;
        self.text_revision += 1;
        self.schedule();
    }
    pub fn newFocusHandle(self: *App) @import("dispatch.zig").FocusHandle {
        const id = self.next_focus;
        self.next_focus += 1;
        return .{ .app = self, .id = id };
    }
    pub fn deinit(self: *App) void {
        defer if (self.text_system) |system| system.release();
        for (self.listeners.items) |entry| entry.destroy(self.allocator, entry.capture);
        for (self.effects.items) |effect| if (effect.destroy) |destroy_payload| destroy_payload(self.allocator, effect.payload.?);
        for (self.slots.items) |slot| if (slot.value) |value| slot.destroy(self.allocator, value);
        self.listeners.deinit(self.allocator);
        self.effects.deinit(self.allocator);
        self.slots.deinit(self.allocator);
    }

    pub fn create(self: *App, value: anytype) !Entity(@TypeOf(value)) {
        const T = @TypeOf(value);
        const ptr = try self.allocator.create(T);
        errdefer self.allocator.destroy(ptr);
        ptr.* = value;
        const Destroy = struct {
            fn call(a: Allocator, raw: *anyopaque) void {
                const p: *T = @ptrCast(@alignCast(raw));
                switch (@typeInfo(T)) {
                    .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(T, "deinit")) p.deinit(),
                    else => {},
                }
                a.destroy(p);
            }
        };
        try self.slots.append(self.allocator, .{ .value = @ptrCast(ptr), .type_name = @typeName(T), .destroy = Destroy.call });
        return .{ .app = self, .id = self.slots.items.len };
    }

    pub fn alive(self: *const App, id: EntityId) bool {
        return id > 0 and id <= self.slots.items.len and self.slots.items[id - 1].value != null;
    }
    pub fn revision(self: *const App, id: EntityId) ?u64 {
        return if (self.alive(id)) self.slots.items[id - 1].revision else null;
    }
    fn validate(self: *App, entity: anytype) !void {
        if (entity.app != self) return error.WrongApp;
        if (!self.alive(entity.id)) return error.EntityReleased;
        if (!std.mem.eql(u8, self.slots.items[entity.id - 1].type_name, @typeName(@TypeOf(entity).Value))) return error.EntityTypeMismatch;
        if (self.slots.items[entity.id - 1].borrowed) return error.EntityBorrowed;
    }
    pub fn destroy(self: *App, entity: anytype) !void {
        try self.validate(entity);
        const slot = self.slots.items[entity.id - 1];
        self.slots.items[entity.id - 1].value = null;
        for (self.listeners.items) |*entry| {
            if (entry.source == entity.id or entry.owner == entity.id) entry.active = false;
        }
        slot.destroy(self.allocator, slot.value.?);
        self.schedule();
    }
    pub fn read(self: *App, entity: anytype) !*const @TypeOf(entity).Value {
        try self.validate(entity);
        try self.track(entity.id);
        return @ptrCast(@alignCast(self.slots.items[entity.id - 1].value.?));
    }
    pub fn track(self: *App, id: EntityId) !void {
        const dependency = Dependency{ .id = id, .revision = self.revision(id) orelse return error.EntityReleased };
        if (self.view_tracking) |tracker| try tracker.record(tracker.context, dependency);
        if (self.tracking) |deps| {
            for (deps.items) |dep| if (dep.id == id) return;
            try deps.append(self.allocator, dependency);
        }
    }
    fn borrow(self: *App, entity: anytype) !*@TypeOf(entity).Value {
        try self.validate(entity);
        self.slots.items[entity.id - 1].borrowed = true;
        return @ptrCast(@alignCast(self.slots.items[entity.id - 1].value.?));
    }
    fn unborrow(self: *App, id: EntityId) void {
        self.slots.items[id - 1].borrowed = false;
    }

    pub fn update(self: *App, entity: anytype, callback: anytype) !void {
        const state = try self.borrow(entity);
        self.depth += 1;
        var cx = Context(@TypeOf(entity).Value){ .app = self, .entity = entity };
        const result: anyerror!void = callback(state, &cx);
        self.unborrow(entity.id);
        self.depth -= 1;
        try self.flush();
        try result;
    }

    /// Update with a by-value argument, retaining the normal borrow/effect boundary.
    pub fn updateWith(self: *App, entity: anytype, argument: anytype, callback: anytype) !void {
        const state = try self.borrow(entity);
        self.depth += 1;
        var cx = Context(@TypeOf(entity).Value){ .app = self, .entity = entity };
        const result: anyerror!void = callback(state, argument, &cx);
        self.unborrow(entity.id);
        self.depth -= 1;
        try self.flush();
        try result;
    }

    /// Coalesces pending notifications. Mutation alone does not notify.
    pub fn notify(self: *App, id: EntityId) !void {
        if (!self.alive(id)) return error.EntityReleased;
        if (self.slots.items[id - 1].pending_notify) return;
        try self.effects.append(self.allocator, .{ .source = id });
        self.slots.items[id - 1].pending_notify = true;
        self.slots.items[id - 1].revision += 1;
        self.schedule();
    }

    pub fn emit(self: *App, source: anytype, event: anytype) !void {
        if (source.app != self) return error.WrongApp;
        if (!self.alive(source.id)) return error.EntityReleased;
        const E = @TypeOf(event);
        const p = try self.allocator.create(E);
        errdefer self.allocator.destroy(p);
        p.* = event;
        try self.effects.append(self.allocator, .{ .source = source.id, .event_type = @typeName(E), .payload = @ptrCast(p), .destroy = boxDestroy(E) });
        self.schedule();
    }

    fn schedule(self: *App) void {
        if (self.wakeup) |wakeup| wakeup.schedule(wakeup.context);
    }

    pub fn observe(self: *App, source: anytype, comptime C: type, capture: C, comptime callback: anytype) !Subscription {
        const S = @TypeOf(source);
        const Adapter = struct {
            fn call(raw: *anyopaque, id: EntityId, _: ?*const anyopaque, app: *App) void {
                callback(@as(*C, @ptrCast(@alignCast(raw))), S{ .app = app, .id = id }, app);
            }
        };
        return self.addListener(source, C, capture, null, Adapter.call);
    }
    pub fn subscribe(self: *App, source: anytype, comptime E: type, comptime C: type, capture: C, comptime callback: anytype) !Subscription {
        const S = @TypeOf(source);
        const Adapter = struct {
            fn call(raw: *anyopaque, id: EntityId, payload: ?*const anyopaque, app: *App) void {
                callback(@as(*C, @ptrCast(@alignCast(raw))), S{ .app = app, .id = id }, @as(*const E, @ptrCast(@alignCast(payload.?))), app);
            }
        };
        return self.addListener(source, C, capture, @typeName(E), Adapter.call);
    }
    fn addListener(self: *App, source: anytype, comptime C: type, capture: C, event_type: ?[]const u8, invoke: @FieldType(Listener, "invoke")) !Subscription {
        if (source.app != self) return error.WrongApp;
        if (!self.alive(source.id)) return error.EntityReleased;
        const ptr = try self.allocator.create(C);
        errdefer self.allocator.destroy(ptr);
        ptr.* = capture;
        const id = self.next_listener;
        try self.listeners.append(self.allocator, .{ .id = id, .source = source.id, .event_type = event_type, .capture = @ptrCast(ptr), .invoke = invoke, .destroy = boxDestroy(C) });
        self.next_listener += 1;
        return .{ .app = self, .id = id };
    }
    fn listener(self: *App, id: u64) ?*Listener {
        for (self.listeners.items) |*entry| if (entry.id == id) return entry;
        return null;
    }

    /// FIFO effect delivery after the outermost update. Reentrant flush is a no-op.
    /// Added listeners start with the next effect; cancellation is immediate.
    pub fn flush(self: *App) !void {
        if (self.depth != 0 or self.flushing) return;
        self.flushing = true;
        defer self.flushing = false;
        var index: usize = 0;
        while (index < self.effects.items.len) : (index += 1) {
            const effect = self.effects.items[index];
            defer if (effect.destroy) |destroy_payload| destroy_payload(self.allocator, effect.payload.?);
            if (!self.alive(effect.source)) continue;
            if (effect.event_type == null) {
                self.slots.items[effect.source - 1].pending_notify = false;
            }
            const end = self.listeners.items.len;
            var i: usize = 0;
            while (i < end) : (i += 1) {
                // Copy before invoking: callbacks may reallocate the listener list.
                const entry = self.listeners.items[i];
                if (!entry.active or entry.source != effect.source) continue;
                if (!sameType(entry.event_type, effect.event_type)) continue;
                entry.invoke(entry.capture, effect.source, effect.payload, self);
            }
        }
        self.effects.clearRetainingCapacity();
        var i: usize = 0;
        while (i < self.listeners.items.len) {
            if (!self.listeners.items[i].active) {
                const entry = self.listeners.orderedRemove(i);
                entry.destroy(self.allocator, entry.capture);
            } else i += 1;
        }
    }
};

fn sameType(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |name| return if (b) |other| std.mem.eql(u8, name, other) else false;
    return b == null;
}
fn boxDestroy(comptime T: type) *const fn (Allocator, *anyopaque) void {
    return struct {
        fn call(a: Allocator, raw: *anyopaque) void {
            a.destroy(@as(*T, @ptrCast(@alignCast(raw))));
        }
    }.call;
}

const g = @import("geometry.zig");

pub const Modifiers = packed struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    command: bool = false,
    caps_lock: bool = false,
    function: bool = false,
};
pub const MouseButton = enum { left, right, middle, back, forward, other };
pub const MouseEvent = struct {
    position: g.Point,
    modifiers: Modifiers = .{},
    button: ?MouseButton = null,
    click_count: u32 = 0,
};
pub const KeyEvent = struct {
    /// Physical platform key code; key is layout-aware UTF-8 or a named key
    /// ("enter", "space", "escape", "left", "f1", etc.).
    key_code: u16,
    key: []const u8,
    modifiers: Modifiers,
    is_repeat: bool = false,
};
pub const ScrollPhase = enum { none, began, changed, ended, cancelled, may_begin };
pub const ScrollEvent = struct {
    position: g.Point,
    delta: g.Point,
    /// Precise deltas are logical pixels; non-precise deltas are lines.
    precise: bool,
    modifiers: Modifiers,
    phase: ScrollPhase = .none,
    momentum_phase: ScrollPhase = .none,
};
pub const TextRange = struct { location: usize, length: usize };
pub const Composition = struct { text: []const u8, selection: TextRange, replacement: ?TextRange };
pub const TextInput = struct { text: []const u8, replacement: ?TextRange = null };
/// Optional focused text model, analogous to GPUI's PlatformInputHandler.
/// Ranges use UTF-16 offsets (the native text services convention). Returned
/// text is borrowed until the query returns to AppKit; bounds are logical and
/// relative to the content view. Mutations arrive through PlatformInput.
pub const TextInputHandler = struct {
    context: *anyopaque,
    selected_range: *const fn (*anyopaque) ?TextRange,
    marked_range: *const fn (*anyopaque) ?TextRange,
    text_for_range: *const fn (*anyopaque, TextRange) ?[]const u8,
    bounds_for_range: *const fn (*anyopaque, TextRange) ?g.Bounds,
    character_index: *const fn (*anyopaque, g.Point) ?usize,
};
/// Strings are borrowed for the duration of dispatch only. Key events are
/// separate from committed text, just as in GPUI's platform input boundary.
pub const PlatformInput = union(enum) {
    mouse_down: MouseEvent,
    mouse_up: MouseEvent,
    mouse_move: MouseEvent,
    mouse_exit: MouseEvent,
    scroll: ScrollEvent,
    key_down: KeyEvent,
    key_up: KeyEvent,
    modifiers_changed: Modifiers,
    text: TextInput,
    marked_text: Composition,
    unmark_text: void,

    pub fn position(self: PlatformInput) ?g.Point {
        return switch (self) {
            .mouse_down, .mouse_up, .mouse_move, .mouse_exit => |e| e.position,
            .scroll => |e| e.position,
            else => null,
        };
    }
};
pub const DispatchEventResult = struct { handled: bool = false };

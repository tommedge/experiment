# zigui

A Zig 0.16 rendering-framework foundation inspired by GPUI, using **real Yoga
3.2.1 flexbox layout** and a **headless, replaceable rendering backend**.

Phase one implements the view/element lifecycle, entity updates, subscriptions,
dependency-based window invalidation, scene construction, and hit testing.
The stub retains scene commands for inspection; it does not rasterize pixels or
open a native window.

## Build and run

```sh
zig build                  # installs zig-out/bin/counter
zig build run              # headless counter demonstration
zig build test --summary all
zig build -Dbackend=stub -Doptimize=ReleaseSafe
```

The first build downloads a content-hash-pinned Yoga release using Zig's package
manager. Zig compiles Yoga's C++20 sources and links libc++; CMake and a separate
C++ compiler are unnecessary. The framework calls Yoga's public C API through
`@cImport`. Yoga remains an external MIT-licensed dependency, including its
upstream license in the downloaded package.

Expected example output:

```text
counter emitted Changed(2)
stub presented 2 frames; bar width: 80; idle redraw: false
```

## Architecture

```text
Entity(T).update(callback)
    Context(T).notify()  ──► coalesced notification + revision + host wakeup
    Context(T).emit(E)   ──► FIFO typed event + host wakeup
             │
             ▼ outermost update completes; entity borrow is released
    observers / event subscribers / subsequent effects
             │
             ▼ host calls Window.drawIfNeeded()
    render → request_layout → compute_layout → prepaint → paint → submit
```

| Module | Responsibility |
| --- | --- |
| `src/app.zig` | Typed entities, contexts, weak handles, deferred effects, subscriptions |
| `src/window.zig` | Dependency tracking, frame scheduling boundary, transactional presentation |
| `src/frame.zig` | Frame arena, phase traversal, hitboxes and scene |
| `src/element.zig` | Type-erased custom elements, phase state, built-in `Div` |
| `src/layout.zig` | Yoga ownership, flex styles and absolute layout bounds |
| `src/scene.zig` | Platform-independent, ordered drawing commands |
| `src/renderer.zig` | Compile-time backend selection and generic renderer contract |
| `src/renderer/stub.zig` | Headless scene capture |

### Frame phases

1. **Render:** `T.render(*const T, *Frame, *Context(T))` constructs a fresh element
   tree from entity state. `Frame.view(entity)` renders a child view. Reads through
   `App.read` / `Entity.read` automatically record window dependencies.
2. **Request layout:** each element recursively requests its children's layouts,
   creates its Yoga node and produces `RequestLayoutState`.
3. **Compute layout:** Yoga resolves the root against the logical viewport size.
   Web defaults are enabled; dimensions use border-box semantics. Yoga rounds
   layout to the configured physical pixel scale.
4. **Prepaint:** elements receive resolved absolute bounds and mutable request
   state, prepare hitboxes, and produce `PrepaintState`.
5. **Paint:** elements receive both states and append ordered primitives to the
   scene. `Div` implements backgrounds, clipping and child traversal.
6. **Submit:** the backend consumes or copies the scene. On success, the window
   commits its dependencies and hitboxes; the temporary tree and Yoga nodes are
   destroyed. On failure, previous presentation metadata remains and a retry is
   scheduled by leaving the window dirty.

Phase checks reject out-of-order or repeated draws. All prepaint traversal
finishes before paint begins. Custom elements control their child traversal.
An element instance belongs to exactly one position in one frame's tree.

The initial style surface supports point/percent/auto dimensions, point min/max
constraints, row/column/reverse directions, grow/shrink/basis, wrapping,
alignment/justification, gap, per-edge point margin/padding, absolute positioning,
display-none, clipping and backgrounds. Coordinates are logical pixels; backend
scale is separate. `layout.c` exposes the upstream API for advanced custom elements.

### Entities, notify and events

```zig
const Changed = struct { value: u32 };

fn increment(self: *Counter, cx: *ui.Context(Counter)) !void {
    self.value += 1;
    try cx.notify();
    try cx.emit(Changed{ .value = self.value });
}

fn onChanged(_: *void, _: ui.Entity(Counter), event: *const Changed, _: *ui.App) void {
    std.debug.print("value: {d}\n", .{event.value});
}

const counter = try app.create(Counter{});
var subscription = try app.subscribe(counter, Changed, void, {}, onChanged);
defer subscription.deinit();
try counter.update(increment);
```

- Mutation is explicit and does **not** automatically notify. A successful
  `notify()` increments the entity revision immediately and queues one observer
  effect. Repeated notifications coalesce while that effect is pending.
- `observe(source, CaptureType, capture, callback)` handles notifications;
  `subscribe(source, EventType, CaptureType, capture, callback)` handles only that
  exact event type from that exact entity. Events are not coalesced. Emitting an
  event alone does not invalidate a view.
- Effects run FIFO after the outermost update, when entities are no longer
  mutably borrowed. Effects emitted by callbacks are processed in the same flush.
  Reentrant flush calls do nothing. Recursive observer feedback must converge.
- Cancelling during delivery immediately suppresses subsequent calls. A listener
  installed during a callback starts with the next effect, not the one currently
  being delivered. Capture boxes are reclaimed after delivery completes.
- `Context(T).observe` and `Context(T).subscribe` additionally bind callbacks to
  the observing entity, supplying mutable state and its context. The binding is
  weak; destroying either endpoint cancels it. See `src/tests.zig` for examples.
- `Subscription.deinit()` cancels; `detach()` relinquishes the handle and leaves
  the listener active until endpoint destruction or app teardown. Use Zig's
  explicit `defer`; merely leaving scope does not cancel a subscription.
- `App.notify` and `App.emit` can also enqueue work outside an entity update.
  Call `App.flush()` to deliver it, or let `Window.drawIfNeeded()` flush it.
- Callback errors are handled by the application: listener callbacks return
  `void`, and fallible work such as `cx.notify()` must be handled explicitly.
  Update callbacks return an error union; mutations and queued effects are kept
  and flushed even if the update returns an error.

### Scheduling and window dependencies

Each window records the entities read while constructing its successful frame.
Only a changed/released dependency, explicit invalidation, or resize requires a
redraw. Each successful render replaces the dependency set, so hidden child
views stop invalidating their former windows. Multiple windows may depend on
the same entity independently. An invalidated window rebuilds its full tree;
subtree caching is a later optimization.

The host owns the event loop. Optionally set `app.wakeup` to a context pointer and
`schedule` function that posts a future UI-loop turn. The host should coalesce
wakeups, flush effects, and call `drawIfNeeded()` for its windows. The scheduler
must not execute UI work inline. The framework and all handles are single-threaded.
This boundary permits a later native platform layer without coupling Yoga or
entity notifications to an OS API.

`Window.hitTest(point)` returns the last matching stable `Div.id`, using the
last successfully presented frame's clipped hitboxes. Input routing can use that
ID to update an entity and emit a typed event. OS input acquisition and bubbling
dispatch are future platform/input-layer work.

### Backend integration

Like Ghostty, a build selects one renderer implementation at compile time.
`-Dbackend=auto` resolves through the target OS policy in `build.zig`; every
platform currently selects `stub`. `-Dbackend=stub` selects it explicitly.

`GenericRenderer(Backend)` requires:

```zig
pub fn init(allocator: std.mem.Allocator, size: Size, scale: f32) !Backend;
pub fn deinit(self: *Backend) void;
pub fn resize(self: *Backend, size: Size, scale: f32) !void;
pub fn submit(self: *Backend, scene: *const Scene) !void;
```

`WindowWithRenderer(GenericRenderer(MyBackend))` also allows an embedding
application to inject a renderer directly. A test uses this path to verify a
failing alternative backend and frame retry.

Backends own their resources. `submit` must consume/copy commands before returning;
no pointers into frame memory may escape. A GPU implementation can copy into
backend-owned in-flight buffers and manage fences internally. Failed submission
must preserve its last successful presentation. The host/platform adapter will
own native window/surface creation; future backend implementations can take
platform-specific configuration in their own constructor wrappers.

### Ownership and scope

- Keep `App` at a stable address after creating handles. It must outlive windows,
  entities, weak handles and subscription handles.
- Entities are **App-owned**, explicitly released using `app.destroy(entity)` or
  at app teardown. This is the deliberate Zig equivalent used here in place of
  GPUI's reference-counted strong handles. Handle copies do not extend lifetime.
  IDs are never reused; released slots remain small tombstones until teardown.
  Stale reads and overlapping mutable borrows return errors.
- Successful `create(value)` transfers the value to the app. If `T` declares
  `deinit(self: *T)`, it is called on release. Failed creation leaves value
  ownership with the caller. Pointers returned by `read` must not be retained
  across entity destruction.
- Event payloads and callback captures are copied **by value**, not deep-cloned.
  Referenced buffers must outlive delivery/subscription respectively. The runtime
  frees the boxes, but does not destroy resources referenced by their fields.
- Element values and both phase states live in the frame arena. Use
  `Frame.allocator()` for their temporary allocations. Put resources requiring
  destructors in entities. `Frame.div()` copies child slices into the arena.
- Yoga nodes/configuration are explicitly freed, including on partial-frame
  failure. Yoga itself allocates via C++; Zig allocation-failure tests cover the
  Zig-owned portion of the pipeline.

This phase intentionally has no GPU implementation, native window/event loop,
text shaping/rasterization, image resources, accessibility, persistent element
state, focus/actions or subtree caching. Scene primitives currently contain
clipped solid quads. These are extension points for later phases, rather than
claims of complete GPUI API compatibility.

## Design references

The implementation follows the lifecycle and reactive concepts from:

- [GPUI Element / Drawable / Render](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/element.rs)
- [GPUI Context notify / observe / subscribe / emit](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/app/context.rs)
- [GPUI Subscription lifecycle and delivery semantics](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/subscription.rs)
- [Ghostty compile-time Renderer selection](https://github.com/ghostty-org/ghostty/blob/main/src/renderer.zig)
- [Yoga 3.2.1](https://github.com/facebook/yoga/tree/v3.2.1)

The test suite exercises real Yoga geometry, phase ordering/state, typed event
delivery, cancellation/reentrancy, owner release, borrow protection, dependency
replacement, clipping, backend substitution/failure, and allocation-failure cleanup.

# zigui

A Zig 0.16 rendering-framework foundation inspired by GPUI, using **real Yoga
3.2.1 flexbox layout**, **native macOS windowing, CoreText shaping and Metal rendering**, and a
headless rendering backend for tests and embedding.

The framework implements the view/element lifecycle, entity updates, subscriptions,
dependency-based window invalidation, scene construction, and hit testing.
Native windows consume the same scenes as the inspection-friendly stub. AppKit
and Metal are called entirely from Zig using `zig-objc`, following `../editor`;
there are no Objective-C or Objective-C++ source files.

## Build and run

```sh
zig build                  # installs zig-out/bin/counter
zig build run              # headless counter demonstration
zig build run-desktop      # move pointer; Space increments; T changes both colors
zig build run-desktop -- --smoke  # verify text/Metal, selective cache reuse and actions
zig build test --summary all
zig build test -Dnative-tests=true --summary all # macOS integration; opens windows
zig build -Dbackend=stub -Doptimize=ReleaseSafe
zig build -Dplatform=stub   # omit native windowing and Apple dependencies
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
| `src/platform.zig` | Type-erased Platform / PlatformWindow interfaces, surface renderer adapter |
| `src/platform/macos.zig` | AppKit event loop, per-window native state, input/text-service translation |
| `src/renderer/metal.zig` | Per-window Metal pipeline, clipped quad upload and presentation |
| `src/input.zig` | Portable mouse, keyboard, scrolling, composition and text-model contracts |
| `src/native_window.zig` | Stable-address bridge from platform callbacks to reactive frames |
| `src/view.zig` | Entity-backed view boundaries and explicit cached-subtree layout/replay |
| `src/view_state.zig` | Committed snapshots, per-view reads, reader indexes and cache ranges |
| `src/dispatch.zig` | View-aware input tree, stable focus, typed actions and contextual keybindings |
| `src/text_system.zig` | Portable fonts, shaped runs, caret positions, wrapping and bounded line cache |
| `src/platform/macos/text.zig` | CoreText font resolution/fallback and CoreGraphics glyph rasterization |
| `src/text.zig` | Styled, Yoga-measured text element |
| `src/renderer/atlas.zig` | Renderer-independent glyph packing and bounded raster cache |
| `src/text/stub.zig` | Explicit deterministic text backend for headless tests |

### Frame phases

1. **View boundaries:** `Frame.view(entity)` constructs an entity-backed boundary.
   It defers calling `T.render(*const T, *Frame, *Context(T))` until that boundary's
   layout traversal. Entity reads are recorded against the active view occurrence.
2. **Request layout:** each element recursively requests its children's layouts,
   creates its Yoga node and produces `RequestLayoutState`. Ordinary view boundaries
   enter a scoped render phase to create their elements before requesting layout.
3. **Compute layout:** Yoga resolves the root against the logical viewport size.
   Web defaults are enabled; dimensions use border-box semantics. Yoga rounds
   layout to the configured physical pixel scale.
4. **Prepaint:** elements receive resolved absolute bounds and mutable request
   state, prepare hitboxes and dispatch nodes, and produce `PrepaintState`. Cached
   boundaries now know their outer bounds: they either replay retained prepaint
   output or perform scoped render/layout/prepaint of their contents.
5. **Paint:** elements receive both states and append ordered primitives to the
   scene. `Div` implements backgrounds, clipping and child traversal.
6. **Submit:** the backend consumes or copies the scene. On success, the window
   commits dependencies, hitboxes, dispatch tree and cache metadata together; the temporary tree and Yoga nodes are
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

### Borders

`Style.border_widths` specifies solid per-edge borders;
`Style.border_color` supplies their shared color. The same style fields work on
`Div`, cached-view boundaries and `TextOptions.layout_style`.

```zig
const panel = try frame.div(.{ .style = .{
    .width = .{ .px = 100 },
    .height = .{ .px = 60 },
    .padding = .all(8),
    .border_widths = .all(2),
    .corner_radii = .all(12),
    .border_color = .{ .r = 0.2, .g = 0.5, .b = 0.8 },
    .clip = true,
} });
// For unequal sides: .border_widths = .{ .left = 3, .bottom = 1 }
// For individual corners: .corner_radii = .{ .top_left = 12, .bottom_right = 6 }
```

Yoga receives the border widths as part of border-box layout. The example's
content width is `100 - 2 - 2 - 8 - 8 = 80` logical pixels. Widths reserve space
even when `border_color` is absent or transparent. Negative/non-finite widths
return `InvalidBorderWidth` before the frame is submitted.

Layout and painting share GPUI-style stroke snapping: positive widths round to
the nearest device pixel, half ties toward zero, with a minimum of one device
pixel. Zero remains zero. For example, a requested `0.25` logical-pixel border
becomes `0.5` logical pixels at 2× scale. `Style.borderWidths(scale)` exposes the
resolved widths, and `contentInsets(scale)` combines them with padding.

Borders paint inside their bounds, over the background and before contents.
`clip = true` clips contents to the padding box inside the border while retaining
the ancestor clip for border/background painting. Hit testing still includes the
element's border box. Cached views retain border output and invalidate it when
width, color, scale or clipping changes; measured text includes borders in its
content width, origin and baseline.

`Scene.box` paints a background and border together. Square boxes keep the solid
quad/strip fast path; rounded boxes retain one `Quad` containing the background,
border widths/color and four corner radii. `Scene.border` also accepts radii for
rounded outlines with transparent interiors. Custom elements use these helpers
with already-snapped logical border widths.

Metal evaluates a GPUI-style signed distance field for the outer rounded edge
and the border's inner edge. Equal adjacent border widths use a circular inner
edge; unequal widths use a quarter-ellipse distance approximation. Half-device-
pixel coverage antialiases both boundaries. Border/background composition happens
in premultiplied space within one fragment, avoiding overlap seams, transparent
corner darkening and division by zero. Clipping trims draw geometry without
changing the original shape coordinates used by the distance calculations.

Radii are logical pixels, scaled for rendering and individually clamped to half
the smaller box dimension, following GPUI's clamped style-radius convention.
Negative/non-finite values return `InvalidCornerRadius`. Radius changes affect
painting and cached-view validity, not Yoga measurements or text baselines.
These radii round the element's own background and border: descendant clipping
and hitboxes remain rectangular. A rounded descendant mask is a separate feature.

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

Each view occurrence records its direct entity reads during render, layout,
prepaint and paint, including its own entity revision. Each window also retains
an aggregate dependency set for `needsDraw()` and an entity-to-reader index.
A changed/released entity dirties every reader and each reader's ancestor views.
Containment and data dependencies are separate structures:

```text
Workspace                 containment       Workspace → Editor / Sidebar
├── Editor → Document     data reads        Editor → Document
└── Sidebar → Settings                      Sidebar → Settings
```

Changing `Document` rebuilds the path through `Workspace` and `Editor`; an
unchanged cached `Sidebar` replays its output. Ordinary views rebuild whenever
their containing traversal reaches them. Reads remain entity-level, not field-level;
mutation requires `notify()`. Successful rebuilds replace dependencies, while
cache hits restore retained dependencies. Removed branches stop invalidating the
window. Multiple readers, occurrences and windows can depend on the same entity.

The host owns the event loop. Optionally set `app.wakeup` to a context pointer and
`schedule` function that posts a future UI-loop turn. The host should coalesce
wakeups, flush effects, and call `drawIfNeeded()` for its windows. The scheduler
must not execute UI work inline. The framework and all handles are single-threaded.
The native platform implements this boundary without coupling Yoga or entity
notifications to an OS API.

`Window.hitTest(point)` returns the last matching stable `Div.id`, using the
last successfully presented frame's clipped hitboxes. Input routing can use that
ID to update an entity and emit a typed event. Native events first pass through
the committed dispatch tree; `NativeWindow.on_input` receives unhandled events
and their hit target as a fallback.

### Explicit cached views

```zig
const editor = try frame.cachedView(editor_entity, .{
    .style = .{ .grow = 1, .height = .{ .percent = 100 }, .clip = true },
});
```

The boundary style participates in parent layout, providing the outer dimensions.
Its contents are laid out in a detached Yoga container using those resolved
dimensions, padding and flex rules. Contents do not contribute intrinsic size
back to the parent; use an ordinary view for content-driven outer sizing.

Reuse requires clean dependency/ancestor state and matching bounds, effective
clip, viewport, scale, boundary style and inherited text style. Replacing the
App's text service or changing its cache generation also refreshes the window.
`Window.invalidate()` explicitly
bypasses caches. Resize and focus changes currently conservatively refresh all
cached views, including views that queried `frame.isFocused(handle)`.

Cached state contains scene ranges, clipped hitboxes, dispatch metadata, direct
dependencies and descendant cache records. A hit skips subtree render, internal
layout, prepaint and paint. Replay copies output into the candidate snapshot and
remaps dispatch IDs and nested ranges; it does not retain temporary elements,
Yoga pointers or a chain of previous frame arenas. Callback captures are owned
and reference-counted across replay. The renderer still receives the complete
ordered scene, including reused primitives.

Identity is the parent view path plus entity ID and instance key. Use
`frame.keyedView(entity, key)` or `.key` in cached-view options when rendering the
same entity more than once beneath one parent. Duplicate identities and recursive
view containment return errors. Moving a view to a different parent establishes
a new occurrence. Focus handles identify individual focusable nodes, so repeated
occurrences must not register the same focus handle simultaneously.

`window.inspect()` returns the current committed snapshot: `views` exposes
parents, direct dependencies, dirty reasons and reuse flags; `readers` maps an
entity to its readers; `view_nodes` maps an entity to dispatch nodes. `cache_hits`
and `cache_misses` count visited cached boundaries in that frame. Descendants of
a fully reused ancestor are marked reused without counting separate lookups.
Treat this inspection data as read-only and borrow it only until the next
successful draw or window teardown.

### Focus, input and actions

Create a stable handle with `app.newFocusHandle()`. Register it with `Div.focus`,
then call `window.focus(handle)` after a successful frame, or `event_context.focus`
from an input listener. `window.blur()` clears focus. A node removed by a
successful frame loses focus automatically.

```zig
const Increment = struct {};

pub fn render(self: *const Counter, f: *ui.Frame, cx: *ui.Context(Counter)) !ui.AnyElement {
    return f.div(.{
        .focus = self.focus_handle,
        .key_context = "Counter",
        .listeners = &.{try f.entityActionListener(cx.entity, Increment, onIncrement)},
        .bindings = &.{try f.bindKey("space", .{}, "Counter", Increment{})},
    });
}

fn onIncrement(self: *Counter, _: *const Increment, phase: ui.DispatchPhase,
    cx: *ui.Context(Counter), event: *ui.EventContext) !void
{
    if (phase != .bubble) return;
    self.value += 1;
    try cx.notify();
    event.stopPropagation();
}
```

- Keyboard, modifiers and text/composition use the focused path, or the root
  content node when no node has focus. Pointer events use the last matching
  clipped hitbox's node, or the root content node when nothing is hit. Assign
  a `Div.id` to create a pointer hit target.
- Listeners run root-to-target during capture, then target-to-root during bubble,
  in registration order within each node. `EventContext.handle()` marks an event
  handled but allows propagation; `stopPropagation()` also stops delivery.
- Raw input listeners run first. Unhandled key-down events resolve bindings
  against named contexts on the focused path. The deepest matching context wins;
  ties prefer the deeper binding owner, then the later registration. An unhandled
  action allows the next matching binding to be tried. This is a single-keystroke
  keymap with exact named contexts and modifiers, rather than GPUI's full predicate
  language and chord/replay machinery.
- `window.dispatchAction(value)` dispatches a typed action directly. Actions are
  distinct from `Context.emit()` subscription events.
- `frame.entityInputListener` and `entityActionListener` retain weak handles and
  invoke callbacks under the standard entity borrow/update boundary. Released
  entities are skipped. These callbacks receive mutable entity state, the event
  or typed action, phase, entity context, and event context.
- `frame.inputListener(capture, callback)` and `actionListener(Action, capture,
  callback)` support custom captures. Successful registration transfers the
  capture by value; an optional `deinit(*Capture)` runs when the final retained
  reference is released. Reference-containing fields are not deep-cloned and
  must outlive the capture. Never capture a frame-arena pointer. Descriptors
  returned by these registration helpers belong to their constructing frame.
- `Frame.configureNode(...)` gives custom elements the same registration surface
  during prepaint; built-in `Div` handles this automatically.
- Dispatch holds the committed tree stable. Reentrant drawing/input returns an
  error; destroy windows outside callbacks. Listener errors propagate to callers
  (`NativeWindow.last_error` for native dispatch).

The desktop example has two independently cached sibling views sharing a palette
entity. Moving the pointer rebuilds the quad view while reusing the sidebar;
**Space** invokes a focused increment action, **T** changes the shared palette
and rebuilds both, and **Cmd-Q** quits. The smoke run asserts selective reuse,
cursor positioning and action updates; normal exit prints render/cache counters.

### Text system

Text follows GPUI's separation of responsibilities:

```text
Font / TextStyle / UTF-8 TextRun
    → TextSystem: resolve FontId, cache LineLayout, wrap visual lines
    → PlatformTextSystem: shape into actual-font ShapedRuns and ShapedGlyphs
    → Text element: Yoga measurement → prepaint → glyph scene primitives
    → renderer atlas: rasterize by font / glyph / size / scale / subpixel phase
    → Metal: ordered solid, coverage and color-glyph batches
```

`Platform.textSystem()` returns the platform's shared text service. Native windows
install it into the App automatically unless another service was supplied using
`app.setTextSystem(system)`. The platform interface owns font resolution, metrics,
line shaping, raster bounds and glyph rasterization. Framework text types contain
no CoreText, CoreGraphics or Metal objects. Its implementation is UI-thread-only,
consistent with the rest of this framework.

On macOS, the implementation adapts the CoreText setup from `../editor`, but
interns the **actual fonts returned by shaped fallback runs** rather than
rasterizing every glyph through one fixed font. Font descriptors specify family,
normal/bold weight and normal/italic style. Fonts are size-independent IDs; shaping
uses logical pixel sizes and rasterization additionally uses backing scale.

```zig
const label = try frame.text("Hello, café 👩‍💻", .{
    .style = .{
        .font = .{ .family = "Helvetica", .weight = .bold },
        .font_size = 18,
        .color = .{ .r = 0.9, .g = 0.9, .b = 1 },
    },
    .wrap = true,
    .layout_style = .{ .max_width = 240 },
});

const styled = try frame.text("Hello world", .{
    .runs = &.{
        .{ .len = 6, .font = .{ .weight = .bold } },
        .{ .len = 5, .color = .{ .r = 0.2, .g = 0.8, .b = 1 } },
    },
});
```

`Div.text_style` supplies inherited overrides; each `Text` can refine them. The
default is 14-pixel Menlo with white text. Optional text-run fonts/colors inherit
when absent. Run lengths cover the entire string in **UTF-8 bytes**, and run ends
must be valid UTF-8 boundaries. Text element creation copies the source, runs and
font-family strings into frame storage, so temporary formatted strings are safe.

Text participates in Yoga through real measurement and baseline callbacks.
Explicit newlines (including CRLF and empty lines) are always respected; `.wrap`
adds width-constrained wrapping. The generic wrapper prefers spaces/hyphens, then
grapheme boundaries, and reshapes each resulting line for contextual joining and
kerning. One grapheme wider than the available width is allowed to overflow;
normal clipping controls visibility. This is a basic wrapper rather than a full
Unicode line-breaking/hyphenation engine. Set `.style.line_height` for an explicit
logical line height. Callback failures abort presentation through the framework's
normal transactional error path.

For custom elements, use `TextSystem.fontId`, `fontMetrics`, `shapeLine`,
`layoutText` and `rasterizeGlyph`. `FontMetrics` are font-space values, scaled by
`font_size / units_per_em`. `LineLayout` exposes actual-font runs, baseline-relative
glyph positions, source byte indexes and grapheme caret positions. Its
`xForIndex`, `closestIndexForX` and `indexForX` helpers use primary caret positions
and do not assume that visual x order matches logical byte order. Native shaping
converts CoreText's UTF-16 indexes into UTF-8 offsets; the separate platform text
**input** interface continues using UTF-16 ranges for AppKit text services.

The shared shaping cache holds up to 128 lines by default, keyed by text, size and
resolved font runs. `shapeLine` returns a retained line: call `line.release()`;
eviction does not invalidate caller-held lines. `layoutText` returns an owned
multiline layout: call `layout.destroy()`. `clearCache()` advances the generation;
hosts should schedule a frame after manually clearing it. `App.setTextSystem`
retains the new service and schedules its own wakeup. Each frame freezes its
selected text service, and emitted glyph scenes retain it independently.

Cached views store glyph descriptors, not atlas tiles or temporary shaped layouts.
Replay retains the descriptors' service references. The stub renderer likewise
owns its captured glyph scene. This preserves old presentation data on failure
and allows text services to be replaced safely while older snapshots exist.

The glyph atlas has separate alpha-coverage and premultiplied RGBA pages. Keys
include service identity/generation, actual font ID, glyph ID, size, scale and
quarter-device-pixel phase. Its default limits are 32 MiB and 8,192 entries. When
historical entries fill it, Metal rebuilds the current frame's glyph set before
creating draw instances; a frame that itself exceeds the budget returns an error
rather than silently omitting glyphs. Color emoji retain their native colors and
use the text color's alpha. Atlas uploads, clipping and batching preserve scene
order, including interleaved translucent quads and glyphs.

Headless callers can explicitly inject the deterministic test backend:

```zig
const fonts = blk: {
    const backend = try ui.text.stub.create(allocator);
    errdefer backend.deinit();
    break :blk try ui.TextSystem.create(allocator, backend);
};
defer fonts.release();
app.setTextSystem(fonts);
```

The test backend uses synthetic monospace metrics and rectangular glyphs; native
windows always use CoreText by default. The desktop demo displays counter labels
and a cached multilingual sample with styled runs, wrapping and color emoji.

### Native macOS integration

```zig
var platform = try ui.Platform.init(app.allocator);
defer platform.deinit();
app.wakeup = .{ .context = &platform, .schedule = ui.Platform.schedule };
defer app.wakeup = null;
const window = try ui.NativeWindow.create(&app, platform, root_entity, .{
    .title = "My window",
    .size = .{ .width = 800, .height = 600 },
});
defer window.destroy();
// Register listeners in views; optionally set window.on_input for unhandled events.
platform.run();
```

`Platform` owns the event loop; `PlatformWindow` owns a native window and renderer.
Both are runtime interfaces with replaceable vtables, inspired by Zed's local
`crates/gpui/src/platform.rs`. `NativeWindow` connects request-frame, resize,
focus, close and input callbacks to the existing `Window` lifecycle. Each native
window has independent Metal resources and callback state. Closing one leaves
others running; closing the last returns from `run`. `quit` also returns normally,
allowing Zig `defer` cleanup. Create and use the platform on the main thread.

App wakeups post coalesced AppKit events. Each event-loop turn checks reactive
dependencies, so idle windows do not submit GPU work. The native view supplies
its Metal layer through `makeBackingLayer` and uses AppKit's
`NSViewLayerContentsRedrawDuringViewResize` policy. `setFrameSize:` updates logical
size, backing scale and drawable dimensions before notifying the framework;
backing-property changes use the same synchronization path.

Geometry changes request a layer redraw rather than presenting directly from
`windowDidResize:`. AppKit's `displayLayer:` callback rebuilds the frame with
`presentsWithTransaction` enabled, pairing the new drawable with the layer's new
bounds in the same Core Animation transaction, including during the nested live-
resize loop. Drawable-size updates disable implicit layer animations. Normal
model updates still use dependency-based redraws. Reentrant display/resize
requests are deferred to the next UI-loop turn, and the presentation mode is
restored even when a frame fails. Unexpected drawable-size mismatches are rejected
instead of presenting a frame at the wrong resolution.
Draw failures remain visible in `NativeWindow.last_error`, preserve dirty state,
and retry on the next event/frame request. Explicit `NativeWindow.invalidate()`
marks the content dirty and wakes the loop.

Input includes all mouse buttons, dragging/motion/exit, click counts, logical
positions, key down/up and repeat, modifier changes, and scroll deltas with units,
gesture and momentum phases. A handled key suppresses text interpretation.
Unconsumed typing goes through AppKit `interpretKeyEvents:` and
`NSTextInputClient`, producing separate committed-text and marked-composition
events, including replacement ranges. Text slices are valid only during dispatch.
Register `Div.text_input = try frame.textInputHandler(capture, Adapter)` for a focused text model to supply
selection/marked ranges, surrounding text, character lookup and candidate-window
bounds. The adapter exposes public `selectedRange`, `markedRange`, `textForRange`,
`boundsForRange` and `characterIndex` methods taking `*Capture`; their remaining
arguments/results match the portable text-input interface. Use weak entity
handles for model-backed adapters and check for release on each query. The native
window installs the focused node's nearest ancestor provider and clears it before
replacing/destroying its snapshot. Custom platform hosts can still use
`surface.setTextInputHandler(...)` directly. Text-service ranges use UTF-16 offsets. Without a handler, composition
events still work, with the candidate window anchored at the content origin.

Window and text callback contexts must outlive their registration. Clear them
before releasing contexts, and destroy windows outside callbacks. `App` and
`Platform` outlive their windows; the `Platform` value used by `app.wakeup` must
stay at a stable address. The framework remains single-threaded.

### Backend integration

Like Ghostty, a build selects one renderer implementation at compile time.
`-Dbackend=auto` resolves through the target OS policy in `build.zig`; every
platform selects `stub` for standalone/headless `Window`. `-Dbackend=stub` selects
it explicitly. Separately, `-Dplatform=auto` selects macOS native windowing on
macOS and no native host elsewhere; native windows own their Metal renderer.

`GenericRenderer(Backend)` requires:

```zig
pub fn init(allocator: std.mem.Allocator, size: Size, scale: f32) !Backend;
pub fn deinit(self: *Backend) void;
pub fn resize(self: *Backend, size: Size, scale: f32) !void;
pub fn submit(self: *Backend, scene: *const Scene) !void;
```

`WindowWithRenderer(GenericRenderer(MyBackend))` also allows an embedding
application to inject a renderer directly. A test uses this path to verify a
failing alternative backend and frame retry. `Window.initWithRenderer` accepts an
already-created renderer, transferring ownership on success. Native windows use
this with `SurfaceRenderer`, which borrows the `PlatformWindow.draw` interface.

Backends own their resources. `submit` must consume/copy commands before returning;
no pointers into frame memory may escape. A GPU implementation can copy into
backend-owned in-flight buffers and manage fences internally. Failed submission
must preserve its last successful presentation. The platform adapter owns native
window/surface creation. Metal uploads per-frame solid/glyph instances, clips them
in logical coordinates, preserves scene order, uses source-alpha blending
and an sRGB drawable for the scene's linear colors. It waits for GPU completion
before presentation, bounding resource lifetime and checking submission errors.
This intentionally simple backend is synchronous rather than a pipelined renderer.

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
- Subscription event payloads and callback captures are copied **by value**, not deep-cloned.
  Referenced buffers must outlive delivery/subscription respectively. The runtime
  frees the boxes, but does not destroy resources referenced by their fields.
- Element values and both phase states live in the frame arena. Use
  `Frame.allocator()` for their temporary allocations. Put resources requiring
  destructors in entities. `Frame.div()` copies child slices into the arena.
- Yoga nodes/configuration are explicitly freed, including on partial-frame
  failure. Yoga itself allocates via C++; Zig allocation-failure tests cover the
  Zig-owned portion of the pipeline.

The current scene contains clipped solid quads and shaped glyphs. General-purpose
image resources, accessibility and a persistent custom-element
state API remain extension points. Cached view state retains rendered output and
dispatch/dependency metadata; temporary custom-element phase state is recreated
on a cache miss. This is a GPUI-inspired foundation, not full API compatibility.

## Design references

The implementation follows the lifecycle and reactive concepts from:

- [GPUI Element / Drawable / Render](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/element.rs)
- [GPUI Context notify / observe / subscribe / emit](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/app/context.rs)
- [GPUI Subscription lifecycle and delivery semantics](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/subscription.rs)
- [GPUI cached view state](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/view.rs)
- [GPUI key dispatch tree](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/key_dispatch.rs)
- [GPUI text system and shaped lines](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/text_system.rs)
- [Ghostty compile-time Renderer selection](https://github.com/ghostty-org/ghostty/blob/main/src/renderer.zig)
- [Yoga 3.2.1](https://github.com/facebook/yoga/tree/v3.2.1)

The test suite exercises real Yoga geometry, phase ordering/state, typed event
delivery, cancellation/reentrancy, owner release, borrow protection, dependency
replacement, per-view readers and ancestor propagation, nested cache reuse,
dispatch remapping, focus/actions/text providers, clipping/layout equivalence,
backend substitution/failure, and allocation-failure cleanup.
Opt-in native tests additionally create two independent Metal windows, render
clipped/translucent scenes, resize, dispatch Unicode text/composition and synthetic
AppKit key events, run the real event loop, verify independent close/teardown, and
dispatch a native keybinding across cached and layer-driven redraws.
Text tests cover UTF-8 run validation, wrapping, measurement, inherited-style cache
invalidation, retained line/glyph ownership, failure rollback and atlas packing.
Native tests cover CoreText fallback, RTL/grapheme indexes, bitmap orientation,
Retina/color rasterization and Metal atlas eviction while replaying a glyph scene.
Border tests cover scale snapping, border-box geometry, translucent corner
coverage, content clipping, cached/ordinary equivalence, text baselines and
allocation-failure cleanup; native tests also submit bordered scenes to Metal.
Rounded-border tests exercise per-corner metadata, radius changes through cached
views and unchanged layout. Native tests read back pixels from the production
Metal rendering path to check corner cutouts, antialiasing, translucent composition,
asymmetric inner ellipses, missing/thick sides and clip correctness at 1× and 2×.
Native resize tests additionally verify immediate size notification, matching
drawable dimensions, transactional display, reentrant-request deferral, failure
cleanup and ignored display callbacks after window close.

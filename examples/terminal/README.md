# Terminal example

A standalone macOS terminal adapted from `../../../editor/src/terminal.zig` and
`pty.zig`, using the same pinned Ghostty VT revision as that editor.

## Run

From the repository root:

```sh
zig build run-terminal -Dterminal=true
zig build run-terminal -Dterminal=true -- /bin/bash --noprofile --norc
zig build run-terminal -Dterminal=true -- /bin/sh -c 'printf "hello\n"'
zig build run-terminal -Dterminal=true -- --smoke
zig build test-terminal -Dterminal=true --summary all
```

Without a command, the example starts `$SHELL -li`, falling back to `/bin/sh` when
`SHELL` is unset. Executable names are resolved against `PATH` before spawning.
The child receives `TERM=xterm-256color`, `COLORTERM=truecolor`, and
`TERM_PROGRAM=zigui-terminal`. It inherits the working directory and other
environment variables. A command's exit status is propagated after teardown;
closing the window or pressing **Cmd-Q** ends the example normally.

The dependency is lazy and this target is opt-in: ordinary framework builds and
tests do not require Ghostty. `zig build -Dterminal=true` also installs
`zig-out/bin/terminal`.

## Behavior

- Ghostty handles VT parsing, the primary/alternate screens, scrollback, colors,
  terminal modes, titles, and terminal-generated replies.
- Menlo at 13 logical pixels is drawn on a fixed grid with 20-pixel rows. Glyphs
  use zigui's generic text system and are anchored to VT cells, including wide
  characters and complete combining/emoji graphemes. Fallback font advances cannot
  shift later columns.
- ANSI foreground/background colors, inverse, faint, bold, italic, invisible,
  underline, overline and strikethrough are rendered. VT sRGB colors are converted
  to the framework's linear color space.
- Box/block characters use the editor's cell-aligned geometry approach. Its
  mixed-weight and double-line junctions remain approximations.
- Arrow/function/navigation keys and Ctrl/Alt combinations use Ghostty's key
  encoder, including application-cursor and Kitty modes. Ordinary Unicode input
  goes through AppKit text input; marked composition is shown at the cursor.
  **Option** acts as **Alt**, sending an escape prefix in legacy mode.
- **Cmd-V** pastes the system clipboard through Ghostty's bracketed-paste encoder.
- Wheel scrolling moves through scrollback; alternate-screen scrolling sends
  arrow keys when enabled. When a program enables mouse reporting, presses,
  releases, drags, movement and vertical wheel events use Ghostty's mouse encoder.
  **Shift-wheel** bypasses mouse reporting.
- Cursor visibility and block/bar/underline styles are honored. An unfocused
  cursor is outlined. The cursor is steady rather than timer-blinking.

This is an embedding example rather than the full Ghostty application. It does
not implement terminal selection/copy/search, image protocols, hyperlink actions,
or cross-cell ligatures/contextual text shaping. Underline variants are rendered
as a simple line. The UI adapter covers common macOS keys rather than Ghostty's
complete platform key translation layer.

## Integration

All terminal-specific code lives in this directory:

| File | Responsibility |
| --- | --- |
| `main.zig` | App/entity ownership, native callbacks, resize, clipboard/IME integration, finite smoke run |
| `model.zig` | VT engine, per-instance responses, mode-aware input encoding, fixed-grid custom element |
| `render_cache.zig` | Retained row scenes, exact row-content checks and fast bounded grapheme caches |
| `pty.zig` | PTY spawning, nonblocking IO thread, queues, resize, cancellation and child reaping |
| `macos.zig` | Example-local main-thread wake bridge and clipboard access |
| `box_drawing.zig` | Geometric box/block characters ported from the editor |
| `tests.zig` | Parser/grid/input tests, real PTY tests and queued-callback cleanup |

The host uses `PlatformWindow`, `WindowWithRenderer(SurfaceRenderer)`, typed entity
updates, custom elements, `TextSystem.shapeLine`, and scene quad/glyph operations.
No terminal-specific UI framework hooks are needed. The native wake bridge exists
here because framework objects are UI-thread-only: the PTY worker only queues
bytes and schedules a main-thread callback.

The PTY has a 4 MiB output queue with backpressure and a bounded input queue. IO is
nonblocking; a cancellation pipe wakes a blocked worker during shutdown. Teardown
joins the producer before closing descriptors, gives the owned child a bounded
HUP grace period, then reaps it. Queued main-thread callbacks are disabled and
drained before their host context is released.

The smoke mode opens a real window and PTY, prints ANSI and Unicode content,
sends a line of input, checks the terminal environment and `stty` dimensions,
presents the final glyph scene, and verifies successful child exit.

## Rendering performance

Input handling and visual invalidation are separate. Sending text, Enter, Ctrl-L,
key releases or mouse reports does not notify the view unless something visible
changes (for example, returning from scrollback to the active viewport). The shell's
resulting output triggers its own update. This avoids rebuilding a populated old
screen while waiting for a clear sequence to arrive.

The example retains a scene for each viewport row. Ghostty's dirty-row flags select
rows to inspect; exact paint-input descriptions filter out conservative dirty flags
caused by cursor movement. Changed rows are staged and committed together, and their
dirty flags are acknowledged only after successful construction. Unchanged rows are
replayed with the current origin and clip. Cursor and preedit are independent overlays.
Resize, backing scale, palette/default colors and text-service generation changes
invalidate the relevant cached data.

ASCII graphemes use direct cache slots per font variant. Other graphemes use a
bounded 1,024-entry hash cache and a reusable UTF-8 scratch buffer. These retain
shaped lines independently of the generic text system's LRU, avoiding per-cell
temporary allocations and repeated linear shape-cache lookups. Adjacent cells with
the same background become a single rectangle, and sRGB conversion uses a lookup
table rather than repeated power calculations.

The full composed scene still goes through the existing renderer. The smoke output
includes row-build, row-reuse and shaping-miss counters; tests verify that a one-row
edit rebuilds one row, cursor-only changes reuse rows, and clearing needs no new
glyph shapes. Use an optimized build when assessing interactive performance:

```sh
zig build run-terminal -Dterminal=true -Doptimize=ReleaseFast
```

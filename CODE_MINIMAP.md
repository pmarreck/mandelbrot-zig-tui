# Code Minimap

## `build.zig`
- `build()` — Zig 0.15 build config: shared module defs, executable, 7 test targets, ReleaseFast default

## `flake.nix`
- `packages.default` — nix build for the mandelbrot binary
- `checks.*.test` — nix check running zig unit tests
- `devShells.default` — dev shell with zig + hyperfine

## `src/main.zig`
- `main()` — entry point: arg parsing (--help, --about, --single-frame), env var injection, app launch
- `parseF128Env()` — parse f128 from environment variable (via f64)
- `parseU32Env()` — parse u32 from environment variable
- `parseU16Env()` — parse u16 from environment variable

## `src/core/mandelbrot.zig`
- `computeIterations(c_re, c_im, max_iter)` — f128 escape-time for single point
- `computeRegion(params, out)` — fill buffer with iteration counts for a grid
- `RegionParams` — struct defining viewport for region computation

## `src/core/viewport.zig`
- `screenToComplex(params)` — map terminal cell to complex coordinate
- `zoomAt(state, factor, col, row, w, h, aspect)` — zoom centered on click point
- `pan(state, direction, w, h, aspect)` — shift center by 10% of visible range
- `adaptiveMaxIter(zoom, base)` — scale iterations with zoom depth (base + 50*log2(zoom))
- `ViewState` — struct: center, zoom, base_iter, max_iter
- `ComplexPoint` — struct: re, im
- `Direction` — enum: up, down, left, right

## `src/core/coloring.zig`
- `iterToCell(iter, max_iter)` — map iteration to Cell (char + fg/bg color)
- `Cell` — struct: char, fg_color, bg_color
- `iterToColor256(iter)` — cyclic HSV gradient through ANSI 216-color cube

## `src/tui/terminal.zig`
- `enterRawMode() / exitRawMode()` — termios save/restore
- `enableMouseTracking() / disableMouseTracking()` — SGR 1006 mouse protocol
- `hideCursor() / showCursor()` — cursor visibility
- `clearScreen()` — clear and home
- `setupSigwinch()` — SIGWINCH handler with atomic flag
- `checkAndClearResizeFlag()` — poll and reset resize flag
- `getTermSizePosix()` — ioctl TIOCGWINSZ (macOS + Linux)
- `TermSize` — struct: cols, rows

## `src/tui/input.zig`
- `parseEvent(bytes)` — parse raw stdin bytes into Event union
- `parseSgrMouse(bytes)` — parse SGR mouse report payload
- `Event` — tagged union: key_q, key_plus, key_minus, arrows, mouse_left/right, etc.
- `MousePos` — struct: col, row

## `src/tui/renderer.zig`
- `renderFrame(state, width, height, allocator)` — pure: state → ANSI byte buffer
- `RenderState` — struct: center, zoom, max_iter, show_info

## `src/tui/app.zig`
- `run(initial_state, allocator)` — main event loop
- `processEvent(state, event)` — pure state transition function
- `defaultState()` — initial AppState with standard defaults
- `AppState` — struct: center, zoom, iters, info, dimensions, flags

## `tests/unit/test_mandelbrot.zig` — escape-time + region computation tests (9 tests)
## `tests/unit/test_viewport.zig` — coordinate mapping, zoom, pan, adaptive iter tests (7 tests)
## `tests/unit/test_coloring.zig` — density chars, color range, gradient smoothness tests (5 tests)
## `tests/unit/test_input.zig` — key, arrow, mouse, Ctrl-C parsing tests (14 tests)
## `tests/unit/test_renderer.zig` — frame output, info bar, determinism tests (4 tests)
## `tests/cli/test_cli.bash` — CLI integration tests: help, about, single-frame, determinism (7 tests)

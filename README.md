[![Garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fmandelbrot-zig-tui%3Fbranch%3Dyolo)](https://garnix.io/repo/pmarreck/mandelbrot-zig-tui)
[![CI](https://github.com/pmarreck/mandelbrot-zig-tui/actions/workflows/ci.yml/badge.svg)](https://github.com/pmarreck/mandelbrot-zig-tui/actions/workflows/ci.yml)

# mandelbrot-zig-tui

An interactive terminal-based Mandelbrot set explorer written in pure Zig.

![Mandelbrot TUI Screenshot](assets/mandelbrot.png)

## Features

- **f128 precision** -- zoom to ~10^-33 depth (far beyond f64's ~15 digits)
- **True-color rendering** -- 24-bit RGB with Bernstein polynomial palette (the classic Wikipedia Mandelbrot gradient) and smooth iteration count coloring via `n + 1 - log2(log2(|z|))`
- **ASCII density texture** -- characters `.:-=+*#%@` provide luminance detail on top of color
- **Mouse navigation** -- left-click to zoom in, right-click to zoom out, drag to pan, scroll wheel zoom at cursor
- **Keyboard navigation** -- `+`/`-` zoom, arrow keys pan, `[`/`]` adjust max iterations, `i` toggle info bar, `q` quit
- **Live drag panning** -- re-renders during drag for smooth visual feedback
- **Adaptive iterations** -- max iterations auto-scale with zoom depth (`base + 50 * log2(zoom)`)
- **SIGWINCH responsive** -- re-renders on terminal resize
- **Bookmarkable views** -- info bar shows a command to restore the exact view via env vars
- **Hexagonal architecture** -- pure computational core (no I/O), TUI adapter for all I/O; designed for easy addition of a C FFI layer

## Screenshot

The screenshot above shows the Mandelbrot set at the default view: centered at (-0.5, 0.0) with the full set visible, rendered with the Bernstein polynomial color palette.

## Building

Requires [Nix](https://nixos.org/download.html) with flakes enabled.

```bash
# Build (ReleaseFast, via nix sandbox)
./build

# Build debug
./build debug

# Run directly
nix develop -c zig build run

# Run tests
./test
```

The binary lands at `zig-out/bin/mandelbrot`.

## Usage

```
mandelbrot [OPTIONS]

Options:
  -h, --help       Show help
  --about          Show version and platform info
  --single-frame   Render one frame to stdout and exit
  --no-color       Disable ANSI colors (future)
  --no-ansi        Disable all ANSI escapes (future)
  --simple         Plain ASCII mode (future)

Controls:
  Left-click       Zoom in 2x at click point
  Right-click      Zoom out 2x at click point
  Drag             Pan (live re-render)
  Scroll wheel     Zoom in/out at cursor
  +/=              Zoom in 2x at center
  -                Zoom out 2x at center
  Arrow keys       Pan
  [/]              Decrease/increase max iterations
  i                Toggle info bar
  q / Ctrl-C       Quit

Environment variables (view injection / bookmarking):
  MANDELBROT_CENTER_RE   Center real coordinate
  MANDELBROT_CENTER_IM   Center imaginary coordinate
  MANDELBROT_ZOOM        Zoom level
  MANDELBROT_MAX_ITER    Max iteration count
  MANDELBROT_COLS        Override terminal width
  MANDELBROT_ROWS        Override terminal height
```

## Architecture

```
src/
  core/                    Pure computation (no I/O)
    mandelbrot.zig         f128 escape-time + smooth iteration count
    viewport.zig           Screen<->complex mapping, zoom, pan
    coloring.zig           Bernstein palette + log transform
  tui/                     I/O adapter layer
    terminal.zig           Raw mode, mouse, SIGWINCH
    input.zig              Byte stream -> Event parser
    renderer.zig           Pure: state -> ANSI buffer
    app.zig                Event loop + state machine
  main.zig                 CLI args, env vars, entry point
```

The core layer is 100% pure functions with no I/O, no allocations beyond caller-provided buffers, and no side effects. This is the natural seam for a future C FFI.

## License

MIT

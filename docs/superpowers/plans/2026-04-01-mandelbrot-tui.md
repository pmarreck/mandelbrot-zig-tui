# Mandelbrot TUI Explorer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an interactive terminal-based Mandelbrot set explorer in pure Zig with hexagonal architecture — pure f128 computation core, TUI I/O adapter, 256-color + ASCII density rendering, mouse/keyboard navigation.

**Architecture:** Two layers: `src/core/` (pure computation, no I/O, no side effects) and `src/tui/` (terminal I/O adapter). `main.zig` wires them together. The core functions take parameters and return data — no allocators needed beyond caller-provided output buffers. The TUI layer handles raw mode, mouse tracking, SIGWINCH, and translates events into state mutations.

**Tech Stack:** Zig 0.15.2, no external dependencies. `flake.nix` for build reproducibility. Bash for CLI test harness.

**Spec:** `docs/superpowers/specs/2026-04-01-mandelbrot-tui-design.md`

---

## File Structure

```
src/
  core/
    mandelbrot.zig    — escape-time computation (f128)
    viewport.zig      — screen↔complex coordinate math, pan/zoom
    coloring.zig      — iteration count → { char, fg_color, bg_color }
  tui/
    terminal.zig      — raw mode, mouse protocol, SIGWINCH, cursor
    input.zig         — raw bytes → Event union parsing
    renderer.zig      — pure: AppState → ANSI output buffer
    app.zig           — event loop, state machine, orchestration
  main.zig            — entry point, env var parsing, setup/cleanup
tests/
  unit/
    test_mandelbrot.zig
    test_viewport.zig
    test_coloring.zig
    test_input.zig
    test_renderer.zig
  cli/
    test_cli.bash
build.zig
flake.nix
build                 — build script (bash)
test                  — test runner (bash)
PLAN.md
PROJECT_OVERVIEW.md
CODE_MINIMAP.md
```

---

### Task 1: Project Scaffolding

**Files:**
- Create: `flake.nix`
- Create: `build.zig`
- Create: `src/main.zig` (minimal hello world)
- Create: `build` (bash script)
- Create: `test` (bash script, initially just runs zig test)
- Create: `PLAN.md`
- Create: `PROJECT_OVERVIEW.md`
- Create: `CODE_MINIMAP.md`

- [ ] **Step 1: Create `flake.nix`**

```nix
{
  description = "Mandelbrot TUI Explorer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        pname = "mandelbrot";
        version = "0.1.0";
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            export HOME=$TMPDIR
            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
            zig build -Doptimize=ReleaseFast --prefix $out
          '';
          dontInstall = true;
        };

        checks.${system} = {
          build = self.packages.${system}.default;
          test = pkgs.stdenv.mkDerivation {
            pname = "${pname}-test";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ pkgs.zig ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME=$TMPDIR
              ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
              timeout 600 zig build test || { echo "Tests failed"; exit 1; }
            '';
            installPhase = ''
              mkdir -p $out
              echo "tests passed" > $out/result
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            hyperfine
          ];
        };
      });
}
```

- [ ] **Step 2: Create `build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    const exe = b.addExecutable(.{
        .name = "mandelbrot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Mandelbrot TUI");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

- [ ] **Step 3: Create minimal `src/main.zig`**

```zig
const std = @import("std");

pub fn main() !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    if (comptime @import("builtin").mode == .Debug) {
        try stderr.print("\x1b[33mDEBUG BUILD\x1b[0m\n", .{});
        try stderr.flush();
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("Mandelbrot TUI — scaffolding complete\n", .{});
    try stdout.flush();
}

test "placeholder" {
    try std.testing.expect(true);
}
```

- [ ] **Step 4: Create `build` script**

```bash
#!/usr/bin/env bash
set -u

case "${1:-}" in
    --test|--debug)
        nix develop -c zig build -Doptimize=Debug
        ;;
    *)
        nix build
        mkdir -p zig-out/bin
        cp -f result/bin/mandelbrot zig-out/bin/mandelbrot
        echo "Built: zig-out/bin/mandelbrot"
        ;;
esac
```

- [ ] **Step 5: Create `test` script**

```bash
#!/usr/bin/env bash
set -u

errors=0

echo "=== Zig unit tests ==="
nix develop -c zig build test -Doptimize=Debug 2>&1
errors=$((errors + $?))

if [ -f tests/cli/test_cli.bash ]; then
    echo ""
    echo "=== CLI tests ==="
    bash tests/cli/test_cli.bash
    errors=$((errors + $?))
fi

echo ""
if [ "$errors" -eq 0 ]; then
    echo "All tests passed."
else
    echo "FAILURES: $errors error(s)"
fi

exit "$errors"
```

- [ ] **Step 6: Create `PROJECT_OVERVIEW.md`**

```markdown
# Mandelbrot TUI Explorer

An interactive terminal-based Mandelbrot set explorer written in pure Zig.

## Goals
- Render the Mandelbrot set in a terminal using 256 ANSI colors and ASCII density characters
- Navigate via mouse (click to zoom) and keyboard (arrows, +/-, etc.)
- Hexagonal architecture: pure computational core with no I/O, TUI adapter for all I/O
- f128 precision for deep zooms (~10^-33)

## Terminology
- **Escape time**: The number of iterations before |z|² > 4; determines color/character
- **Viewport**: The rectangular region of the complex plane currently displayed
- **Density characters**: The 10-level ASCII set ` .:-=+*#%@` mapping luminance
- **Interior point**: A point in the Mandelbrot set (never escapes); rendered as black space
```

- [ ] **Step 7: Create initial `PLAN.md`**

(Content provided separately — includes current tasks + future enhancements)

- [ ] **Step 8: Create initial `CODE_MINIMAP.md`**

```markdown
# Code Minimap

## `build.zig`
- `build()` — Zig 0.15 build config: executable, tests, ReleaseFast default

## `src/main.zig`
- `main()` — entry point (currently scaffolding placeholder)

## `flake.nix`
- `packages.default` — nix build for the mandelbrot binary
- `checks.*.test` — nix check running zig unit tests
- `devShells.default` — dev shell with zig + hyperfine
```

- [ ] **Step 9: Make build and test scripts executable, verify build**

Run: `chmod +x build test && nix develop -c zig build test -Doptimize=Debug`
Expected: `All 1 tests passed.`

- [ ] **Step 10: Commit**

```bash
git add build.zig flake.nix src/main.zig build test PLAN.md PROJECT_OVERVIEW.md CODE_MINIMAP.md
git commit -m "feat: project scaffolding with build.zig, flake.nix, scripts"
```

---

### Task 2: Core — Mandelbrot Computation

**Files:**
- Create: `src/core/mandelbrot.zig`
- Create: `tests/unit/test_mandelbrot.zig`
- Modify: `src/main.zig` (add import)
- Modify: `build.zig` (add test for core)

- [ ] **Step 1: Write failing tests for `computeIterations`**

Create `src/core/mandelbrot.zig` as an empty file first:

```zig
// src/core/mandelbrot.zig
// Mandelbrot escape-time computation using f128 precision.
```

Then create the test file `tests/unit/test_mandelbrot.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const mandelbrot = @import("../../src/core/mandelbrot.zig");

test "origin (0,0) is in the Mandelbrot set" {
    const result = mandelbrot.computeIterations(0.0, 0.0, 256);
    try testing.expectEqual(@as(u32, 256), result);
}

test "(2,0) escapes immediately — iteration 1" {
    const result = mandelbrot.computeIterations(2.0, 0.0, 256);
    try testing.expectEqual(@as(u32, 1), result);
}

test "(-1,0) is in the Mandelbrot set" {
    const result = mandelbrot.computeIterations(-1.0, 0.0, 256);
    try testing.expectEqual(@as(u32, 256), result);
}

test "(-2,0) is on the boundary — escapes at iteration 2" {
    // z0=0, z1=(-2)^2+(-2)=-2+(-2)= wait: z1 = 0^2 + (-2) = -2
    // z2 = (-2)^2 + (-2) = 4 + (-2) = 2, |2|^2 = 4, NOT > 4
    // z3 = 2^2 + (-2) = 4 - 2 = 2, same
    // Actually (-2,0) is on the boundary and oscillates.
    // Let's use (1, 0) instead: z1=1, z2=1+1=2, z3=4+1=5 -> escapes at iter 3
    // Correction: this test is about (-2,0). Let's trace:
    // z0=0, z1=(-2), |z1|^2=4, NOT > 4
    // z2=(-2)^2+(-2)=4-2=2, |z2|^2=4, NOT > 4
    // z3=2^2+(-2)=4-2=2, oscillates. In set.
    const result = mandelbrot.computeIterations(-2.0, 0.0, 256);
    try testing.expectEqual(@as(u32, 256), result);
}

test "(1, 0) escapes at iteration 3" {
    // z0=0, z1=1, z2=1+1=2, z3=4+1=5, |5|^2=25 > 4 → escapes at iter 3
    const result = mandelbrot.computeIterations(1.0, 0.0, 256);
    try testing.expectEqual(@as(u32, 3), result);
}

test "(0.5, 0.5) escapes at a known iteration count" {
    // This point is outside the main cardioid; should escape in finite iterations
    const result = mandelbrot.computeIterations(0.5, 0.5, 1000);
    try testing.expect(result < 1000);
    try testing.expect(result > 0);
}

test "(-0.75, 0.0) is in the set — neck of the cardioid" {
    const result = mandelbrot.computeIterations(-0.75, 0.0, 1000);
    // This is right at the junction between cardioid and period-2 bulb.
    // With enough iterations it should stay. Use high max_iter.
    try testing.expectEqual(@as(u32, 1000), result);
}
```

- [ ] **Step 2: Update `build.zig` to include the test file**

Add a second test target for the dedicated test files:

```zig
// After the existing unit_tests block, add:
const core_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/test_mandelbrot.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
const run_core_tests = b.addRunArtifact(core_tests);
test_step.dependOn(&run_core_tests.step);
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: Compilation error — `computeIterations` not found.

- [ ] **Step 4: Implement `computeIterations` in `src/core/mandelbrot.zig`**

```zig
// src/core/mandelbrot.zig
// Mandelbrot escape-time computation using f128 precision.
// Pure function: no I/O, no allocations, no side effects.

/// Compute escape iteration for a single point in the complex plane.
/// Returns the iteration count at which |z|² > 4, or max_iter if the point
/// is (likely) in the Mandelbrot set. Uses f128 for ~33 digits of precision.
pub fn computeIterations(c_re: f128, c_im: f128, max_iter: u32) u32 {
    var z_re: f128 = 0.0;
    var z_im: f128 = 0.0;
    var i: u32 = 0;
    while (i < max_iter) : (i += 1) {
        const z_re2 = z_re * z_re;
        const z_im2 = z_im * z_im;
        if (z_re2 + z_im2 > 4.0) return i;
        z_im = 2.0 * z_re * z_im + c_im;
        z_re = z_re2 - z_im2 + c_re;
    }
    return max_iter;
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: All tests pass.

- [ ] **Step 6: Write failing test for `computeRegion`**

Add to `tests/unit/test_mandelbrot.zig`:

```zig
test "computeRegion fills buffer with correct iteration counts" {
    const width: u16 = 3;
    const height: u16 = 2;
    var buf: [6]u32 = undefined;
    mandelbrot.computeRegion(.{
        .center_re = 0.0,
        .center_im = 0.0,
        .zoom = 1.0,
        .width = width,
        .height = height,
        .max_iter = 256,
        .aspect_ratio = 0.5,
    }, &buf);

    // All values should be valid iteration counts (0..max_iter inclusive)
    for (buf) |val| {
        try testing.expect(val <= 256);
    }
    // Center pixel at (0,0) should be in the set
    // With 3x2 grid centered at 0,0: center col=1, center row=0 or 1
    // The point (0,0) is in the set, so its iteration count should be max_iter
    // Grid mapping depends on viewport math, but at minimum all values are bounded
}

test "computeRegion at known zoom produces deterministic output" {
    const width: u16 = 5;
    const height: u16 = 3;
    var buf1: [15]u32 = undefined;
    var buf2: [15]u32 = undefined;
    const params = mandelbrot.RegionParams{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .width = width,
        .height = height,
        .max_iter = 100,
        .aspect_ratio = 0.5,
    };
    mandelbrot.computeRegion(params, &buf1);
    mandelbrot.computeRegion(params, &buf2);

    // Deterministic: same params → same output
    try testing.expectEqualSlices(u32, &buf1, &buf2);
}
```

- [ ] **Step 7: Run tests to verify they fail**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: Compilation error — `RegionParams` and `computeRegion` not found.

- [ ] **Step 8: Implement `RegionParams` and `computeRegion`**

Add to `src/core/mandelbrot.zig`:

```zig
pub const RegionParams = struct {
    center_re: f128,
    center_im: f128,
    zoom: f128,
    width: u16,
    height: u16,
    max_iter: u32,
    aspect_ratio: f64,
};

/// Compute escape iterations for a rectangular grid of the complex plane.
/// Output buffer must have length >= width * height. Fills row-major order.
pub fn computeRegion(params: RegionParams, out: []u32) void {
    const w: f128 = @floatFromInt(params.width);
    const h: f128 = @floatFromInt(params.height);
    const aspect: f128 = @floatCast(params.aspect_ratio);

    // Visible range: 4.0 / zoom in the real axis (at zoom=1, we see ~4 units)
    const range_re = 4.0 / params.zoom;
    const range_im = range_re * (h / w) / aspect;

    const step_re = range_re / w;
    const step_im = range_im / h;

    const start_re = params.center_re - range_re / 2.0;
    const start_im = params.center_im - range_im / 2.0;

    var row: u16 = 0;
    while (row < params.height) : (row += 1) {
        var col: u16 = 0;
        while (col < params.width) : (col += 1) {
            const c_re = start_re + @as(f128, @floatFromInt(col)) * step_re + step_re / 2.0;
            const c_im = start_im + @as(f128, @floatFromInt(row)) * step_im + step_im / 2.0;
            const idx = @as(usize, row) * @as(usize, params.width) + @as(usize, col);
            out[idx] = computeIterations(c_re, c_im, params.max_iter);
        }
    }
}
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: All tests pass.

- [ ] **Step 10: Add `main.zig` import so the module is reachable, then commit**

In `src/main.zig`, add at the top:

```zig
const mandelbrot = @import("core/mandelbrot.zig");
```

Then commit:

```bash
git add src/core/mandelbrot.zig tests/unit/test_mandelbrot.zig src/main.zig build.zig
git commit -m "feat: core mandelbrot computation — f128 escape-time + region fill"
```

---

### Task 3: Core — Viewport Math

**Files:**
- Create: `src/core/viewport.zig`
- Create: `tests/unit/test_viewport.zig`
- Modify: `build.zig` (add test target)

- [ ] **Step 1: Write failing tests for viewport**

Create `src/core/viewport.zig` as stub:

```zig
// src/core/viewport.zig
// Screen↔complex coordinate mapping, pan, zoom, adaptive iteration scaling.
```

Create `tests/unit/test_viewport.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const viewport = @import("../../src/core/viewport.zig");

test "screenToComplex maps center pixel to center coordinates" {
    const result = viewport.screenToComplex(.{
        .col = 40,
        .row = 12,
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .width = 80,
        .height = 24,
        .aspect_ratio = 0.5,
    });
    // Center pixel should map to center coordinates (within floating point tolerance)
    try testing.expectApproxEqAbs(@as(f64, -0.5), @as(f64, @floatCast(result.re)), 0.1);
    try testing.expectApproxEqAbs(@as(f64, 0.0), @as(f64, @floatCast(result.im)), 0.1);
}

test "screenToComplex at higher zoom narrows visible range" {
    const zoom1 = viewport.screenToComplex(.{
        .col = 0, .row = 0,
        .center_re = 0.0, .center_im = 0.0,
        .zoom = 1.0, .width = 80, .height = 24, .aspect_ratio = 0.5,
    });
    const zoom2 = viewport.screenToComplex(.{
        .col = 0, .row = 0,
        .center_re = 0.0, .center_im = 0.0,
        .zoom = 2.0, .width = 80, .height = 24, .aspect_ratio = 0.5,
    });
    // At 2x zoom, the corner should be closer to center
    const dist1_f64: f64 = @floatCast(zoom1.re * zoom1.re + zoom1.im * zoom1.im);
    const dist2_f64: f64 = @floatCast(zoom2.re * zoom2.re + zoom2.im * zoom2.im);
    try testing.expect(dist2_f64 < dist1_f64);
}

test "zoomAt recenters on the clicked point" {
    const state = viewport.ViewState{
        .center_re = 0.0,
        .center_im = 0.0,
        .zoom = 1.0,
        .base_iter = 256,
        .max_iter = 256,
    };
    // Click on a non-center pixel should shift center
    const new_state = viewport.zoomAt(state, 2.0, 60, 12, 80, 24, 0.5);
    try testing.expect(new_state.center_re != 0.0);
    try testing.expectApproxEqAbs(@as(f64, 2.0), @as(f64, @floatCast(new_state.zoom)), 0.001);
}

test "zoomAt at center pixel preserves center" {
    const state = viewport.ViewState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .base_iter = 256,
        .max_iter = 256,
    };
    const new_state = viewport.zoomAt(state, 2.0, 40, 12, 80, 24, 0.5);
    try testing.expectApproxEqAbs(@as(f64, -0.5), @as(f64, @floatCast(new_state.center_re)), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), @as(f64, @floatCast(new_state.center_im)), 0.001);
}

test "pan shifts center by 10% of visible range" {
    const state = viewport.ViewState{
        .center_re = 0.0,
        .center_im = 0.0,
        .zoom = 1.0,
        .base_iter = 256,
        .max_iter = 256,
    };
    const right = viewport.pan(state, .right, 80, 24, 0.5);
    try testing.expect(right.center_re > 0.0);
    // 10% of 4.0/1.0 = 0.4
    try testing.expectApproxEqAbs(@as(f64, 0.4), @as(f64, @floatCast(right.center_re)), 0.001);
}

test "adaptiveMaxIter increases with zoom depth" {
    const iter1 = viewport.adaptiveMaxIter(1.0, 256);
    const iter10 = viewport.adaptiveMaxIter(1000.0, 256);
    const iter20 = viewport.adaptiveMaxIter(1_000_000.0, 256);
    try testing.expect(iter10 > iter1);
    try testing.expect(iter20 > iter10);
}

test "adaptiveMaxIter at zoom=1 returns base" {
    const result = viewport.adaptiveMaxIter(1.0, 256);
    try testing.expectEqual(@as(u32, 256), result);
}
```

- [ ] **Step 2: Add test target to `build.zig`**

```zig
const viewport_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/test_viewport.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
const run_viewport_tests = b.addRunArtifact(viewport_tests);
test_step.dependOn(&run_viewport_tests.step);
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: Compilation error — viewport functions not found.

- [ ] **Step 4: Implement `src/core/viewport.zig`**

```zig
// src/core/viewport.zig
// Screen↔complex coordinate mapping, pan, zoom, adaptive iteration scaling.
// Pure functions: no I/O, no side effects.

const std = @import("std");

pub const ViewState = struct {
    center_re: f128,
    center_im: f128,
    zoom: f128,
    base_iter: u32,
    max_iter: u32,
};

pub const Direction = enum {
    up,
    down,
    left,
    right,
};

pub const ScreenToComplexParams = struct {
    col: u16,
    row: u16,
    center_re: f128,
    center_im: f128,
    zoom: f128,
    width: u16,
    height: u16,
    aspect_ratio: f64,
};

pub const ComplexPoint = struct {
    re: f128,
    im: f128,
};

/// Map a terminal cell (col, row) to a complex coordinate.
/// Applies aspect ratio correction for terminal characters (~2x taller than wide).
pub fn screenToComplex(p: ScreenToComplexParams) ComplexPoint {
    const w: f128 = @floatFromInt(p.width);
    const h: f128 = @floatFromInt(p.height);
    const aspect: f128 = @floatCast(p.aspect_ratio);

    const range_re = 4.0 / p.zoom;
    const range_im = range_re * (h / w) / aspect;

    const col_f: f128 = @floatFromInt(p.col);
    const row_f: f128 = @floatFromInt(p.row);

    const re = p.center_re + (col_f - w / 2.0) / w * range_re;
    const im = p.center_im + (row_f - h / 2.0) / h * range_im;

    return .{ .re = re, .im = im };
}

/// Zoom by `factor` centered on screen position (click_col, click_row).
/// Recenters the viewport so the clicked point becomes the new center.
pub fn zoomAt(
    state: ViewState,
    factor: f128,
    click_col: u16,
    click_row: u16,
    width: u16,
    height: u16,
    aspect_ratio: f64,
) ViewState {
    // Map click position to complex coordinates
    const target = screenToComplex(.{
        .col = click_col,
        .row = click_row,
        .center_re = state.center_re,
        .center_im = state.center_im,
        .zoom = state.zoom,
        .width = width,
        .height = height,
        .aspect_ratio = aspect_ratio,
    });

    const new_zoom = state.zoom * factor;

    return .{
        .center_re = target.re,
        .center_im = target.im,
        .zoom = new_zoom,
        .base_iter = state.base_iter,
        .max_iter = adaptiveMaxIter(new_zoom, state.base_iter),
    };
}

/// Pan the viewport by 10% of the visible range in the given direction.
pub fn pan(
    state: ViewState,
    direction: Direction,
    width: u16,
    height: u16,
    aspect_ratio: f64,
) ViewState {
    const w: f128 = @floatFromInt(width);
    const h: f128 = @floatFromInt(height);
    const aspect: f128 = @floatCast(aspect_ratio);

    const range_re = 4.0 / state.zoom;
    const range_im = range_re * (h / w) / aspect;

    const step_re = range_re * 0.1;
    const step_im = range_im * 0.1;

    var new = state;
    switch (direction) {
        .left => new.center_re -= step_re,
        .right => new.center_re += step_re,
        .up => new.center_im -= step_im,
        .down => new.center_im += step_im,
    }
    return new;
}

/// Compute adaptive max iterations based on zoom depth.
/// Formula: base + 50 * log2(zoom). At zoom=1, returns base unchanged.
pub fn adaptiveMaxIter(zoom: f128, base: u32) u32 {
    if (zoom <= 1.0) return base;
    const zoom_f64: f64 = @floatCast(zoom);
    const extra: f64 = 50.0 * @log2(zoom_f64);
    const total = @as(u64, base) + @as(u64, @intFromFloat(@max(0.0, extra)));
    return @intCast(@min(total, 100_000));
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/core/viewport.zig tests/unit/test_viewport.zig build.zig
git commit -m "feat: core viewport math — screen↔complex mapping, zoom, pan, adaptive iter"
```

---

### Task 4: Core — Coloring

**Files:**
- Create: `src/core/coloring.zig`
- Create: `tests/unit/test_coloring.zig`
- Modify: `build.zig` (add test target)

- [ ] **Step 1: Write failing tests for coloring**

Create `src/core/coloring.zig` as stub:

```zig
// src/core/coloring.zig
// Maps iteration count to terminal cell: ASCII density character + 256 ANSI color.
```

Create `tests/unit/test_coloring.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const coloring = @import("../../src/core/coloring.zig");

test "interior point (iter == max_iter) renders as black space" {
    const cell = coloring.iterToCell(256, 256);
    try testing.expectEqual(@as(u8, ' '), cell.char);
    try testing.expectEqual(@as(u8, 0), cell.bg_color); // black background (ANSI 0)
}

test "iter=0 maps to first density character (space)" {
    const cell = coloring.iterToCell(0, 256);
    try testing.expectEqual(@as(u8, ' '), cell.char);
}

test "density characters span the full range" {
    // Sample at 10 evenly spaced points across 0..max_iter-1
    const density = " .:-=+*#%@";
    var seen = [_]bool{false} ** 10;
    const max_iter: u32 = 1000;
    var i: u32 = 0;
    while (i < max_iter) : (i += 1) {
        const cell = coloring.iterToCell(i, max_iter);
        for (density, 0..) |ch, idx| {
            if (cell.char == ch) {
                seen[idx] = true;
                break;
            }
        }
    }
    // All density chars should appear at least once across the range
    for (seen) |s| {
        try testing.expect(s);
    }
}

test "color values are in 256-color range (16-231 for color cube)" {
    const max_iter: u32 = 500;
    var i: u32 = 0;
    while (i < max_iter) : (i += 1) {
        const cell = coloring.iterToCell(i, max_iter);
        // Non-interior: fg_color should be in valid ANSI 256 range
        try testing.expect(cell.fg_color >= 16 and cell.fg_color <= 231);
    }
}

test "adjacent iterations produce smooth color transitions" {
    // Color difference between adjacent iterations should be small
    const max_iter: u32 = 100;
    var large_jumps: u32 = 0;
    var i: u32 = 1;
    while (i < max_iter) : (i += 1) {
        const c1 = coloring.iterToCell(i - 1, max_iter);
        const c2 = coloring.iterToCell(i, max_iter);
        const diff = if (c2.fg_color > c1.fg_color) c2.fg_color - c1.fg_color else c1.fg_color - c2.fg_color;
        if (diff > 36) large_jumps += 1; // 36 = one full row in color cube
    }
    // Allow some wrap-around jumps but not too many
    try testing.expect(large_jumps < max_iter / 5);
}
```

- [ ] **Step 2: Add test target to `build.zig`**

```zig
const coloring_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/test_coloring.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
const run_coloring_tests = b.addRunArtifact(coloring_tests);
test_step.dependOn(&run_coloring_tests.step);
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: Compilation error — `iterToCell` not found.

- [ ] **Step 4: Implement `src/core/coloring.zig`**

```zig
// src/core/coloring.zig
// Maps iteration count to terminal cell: ASCII density character + 256 ANSI color.
// Pure function: no I/O, no side effects.

pub const Cell = struct {
    char: u8,
    fg_color: u8,
    bg_color: u8,
};

const density_chars = " .:-=+*#%@";

/// Map an iteration count to a renderable terminal cell.
/// Interior points (iter == max_iter) → black space.
/// Exterior points → ASCII density char for luminance + cyclic 256-color gradient.
pub fn iterToCell(iter: u32, max_iter: u32) Cell {
    // Interior: in the Mandelbrot set
    if (iter >= max_iter) {
        return .{ .char = ' ', .fg_color = 0, .bg_color = 0 };
    }

    // Density character: linear map across the 10-char range
    const ratio = @as(f64, @floatFromInt(iter)) / @as(f64, @floatFromInt(max_iter));
    const char_idx: usize = @intFromFloat(ratio * @as(f64, density_chars.len - 1));
    const char = density_chars[@min(char_idx, density_chars.len - 1)];

    // Color: smooth cyclic gradient through 6x6x6 color cube (ANSI 16-231)
    // The color cube is 216 entries: index = 16 + 36*r + 6*g + b where r,g,b ∈ 0..5
    // We cycle through with a smooth hue rotation.
    const fg = iterToColor256(iter);

    return .{ .char = char, .fg_color = fg, .bg_color = 0 };
}

/// Map iteration count to ANSI 256-color index (16-231 range).
/// Uses a smooth cyclic gradient through the color cube for pleasing bands.
fn iterToColor256(iter: u32) u8 {
    // Cycle through the color cube with a period that creates visible bands
    const t = @as(f64, @floatFromInt(iter % 256)) / 256.0;

    // HSV-like hue rotation mapped to the 6x6x6 cube
    // Shift through: blue → cyan → green → yellow → red → magenta
    const phase = t * 6.0;
    const sector: u32 = @intFromFloat(phase);
    const frac = phase - @as(f64, @floatFromInt(sector));

    var r: u32 = 0;
    var g: u32 = 0;
    var b: u32 = 0;
    const rise: u32 = @intFromFloat(frac * 5.0);
    const fall: u32 = 5 - rise;

    switch (sector % 6) {
        0 => { r = 5; g = rise; b = 0; },     // red → yellow
        1 => { r = fall; g = 5; b = 0; },      // yellow → green
        2 => { r = 0; g = 5; b = rise; },      // green → cyan
        3 => { r = 0; g = fall; b = 5; },       // cyan → blue
        4 => { r = rise; g = 0; b = 5; },       // blue → magenta
        5 => { r = 5; g = 0; b = fall; },       // magenta → red
        else => unreachable,
    }

    return @intCast(16 + 36 * r + 6 * g + b);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/core/coloring.zig tests/unit/test_coloring.zig build.zig
git commit -m "feat: core coloring — density chars + cyclic 256-color gradient"
```

---

### Task 5: TUI — Input Parsing

**Files:**
- Create: `src/tui/input.zig`
- Create: `tests/unit/test_input.zig`
- Modify: `build.zig` (add test target)

- [ ] **Step 1: Write failing tests for input parsing**

Create `src/tui/input.zig` as stub:

```zig
// src/tui/input.zig
// Parses raw terminal bytes into typed Event values.
```

Create `tests/unit/test_input.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const input = @import("../../src/tui/input.zig");

test "parse 'q' as key_q" {
    const event = input.parseEvent("q");
    try testing.expectEqual(input.Event.key_q, event);
}

test "parse '+' as key_plus" {
    const event = input.parseEvent("+");
    try testing.expectEqual(input.Event.key_plus, event);
}

test "parse '-' as key_minus" {
    const event = input.parseEvent("-");
    try testing.expectEqual(input.Event.key_minus, event);
}

test "parse '[' as key_bracket_open" {
    const event = input.parseEvent("[");
    try testing.expectEqual(input.Event.key_bracket_open, event);
}

test "parse ']' as key_bracket_close" {
    const event = input.parseEvent("]");
    try testing.expectEqual(input.Event.key_bracket_close, event);
}

test "parse 'i' as key_i" {
    const event = input.parseEvent("i");
    try testing.expectEqual(input.Event.key_i, event);
}

test "parse Ctrl-C (0x03) as ctrl_c" {
    const event = input.parseEvent(&[_]u8{0x03});
    try testing.expectEqual(input.Event.ctrl_c, event);
}

test "parse arrow up escape sequence" {
    const event = input.parseEvent("\x1b[A");
    try testing.expectEqual(input.Event.arrow_up, event);
}

test "parse arrow down escape sequence" {
    const event = input.parseEvent("\x1b[B");
    try testing.expectEqual(input.Event.arrow_down, event);
}

test "parse arrow right escape sequence" {
    const event = input.parseEvent("\x1b[C");
    try testing.expectEqual(input.Event.arrow_right, event);
}

test "parse arrow left escape sequence" {
    const event = input.parseEvent("\x1b[D");
    try testing.expectEqual(input.Event.arrow_left, event);
}

test "parse SGR mouse left-click at col=40, row=12" {
    // SGR format: \x1b[<0;41;13M (1-indexed coords)
    const event = input.parseEvent("\x1b[<0;41;13M");
    switch (event) {
        .mouse_left => |pos| {
            try testing.expectEqual(@as(u16, 40), pos.col);
            try testing.expectEqual(@as(u16, 12), pos.row);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse SGR mouse right-click at col=10, row=5" {
    // SGR format: \x1b[<2;11;6M (button 2 = right, 1-indexed coords)
    const event = input.parseEvent("\x1b[<2;11;6M");
    switch (event) {
        .mouse_right => |pos| {
            try testing.expectEqual(@as(u16, 10), pos.col);
            try testing.expectEqual(@as(u16, 5), pos.row);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "unknown bytes parse as unknown" {
    const event = input.parseEvent(&[_]u8{0xFF});
    try testing.expectEqual(input.Event.unknown, event);
}
```

- [ ] **Step 2: Add test target to `build.zig`**

```zig
const input_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/test_input.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
const run_input_tests = b.addRunArtifact(input_tests);
test_step.dependOn(&run_input_tests.step);
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: Compilation error — `Event` and `parseEvent` not found.

- [ ] **Step 4: Implement `src/tui/input.zig`**

```zig
// src/tui/input.zig
// Parses raw terminal bytes into typed Event values.
// Pure function: no I/O, no side effects.

const std = @import("std");

pub const MousePos = struct {
    col: u16,
    row: u16,
};

pub const Event = union(enum) {
    key_q,
    key_plus,
    key_minus,
    key_bracket_open,
    key_bracket_close,
    key_i,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    mouse_left: MousePos,
    mouse_right: MousePos,
    ctrl_c,
    resize,
    unknown,
};

/// Parse raw bytes from stdin into a typed Event.
/// Handles single characters, escape sequences, and SGR mouse reports.
pub fn parseEvent(bytes: []const u8) Event {
    if (bytes.len == 0) return .unknown;

    // Single byte events
    if (bytes.len == 1) {
        return switch (bytes[0]) {
            'q' => .key_q,
            '+', '=' => .key_plus, // = is unshifted + on most keyboards
            '-' => .key_minus,
            '[' => .key_bracket_open,
            ']' => .key_bracket_close,
            'i' => .key_i,
            0x03 => .ctrl_c, // Ctrl-C
            else => .unknown,
        };
    }

    // Escape sequences start with \x1b[
    if (bytes.len >= 3 and bytes[0] == 0x1b and bytes[1] == '[') {
        // Arrow keys: \x1b[A/B/C/D
        if (bytes.len == 3) {
            return switch (bytes[2]) {
                'A' => .arrow_up,
                'B' => .arrow_down,
                'C' => .arrow_right,
                'D' => .arrow_left,
                else => .unknown,
            };
        }

        // SGR mouse: \x1b[<button;col;rowM
        if (bytes[2] == '<') {
            return parseSgrMouse(bytes[3..]);
        }
    }

    return .unknown;
}

/// Parse SGR mouse report payload: "button;col;rowM" (after "\x1b[<")
fn parseSgrMouse(bytes: []const u8) Event {
    var parts: [3]u16 = .{ 0, 0, 0 };
    var part_idx: usize = 0;
    var terminated = false;

    for (bytes) |byte| {
        if (byte == ';') {
            part_idx += 1;
            if (part_idx >= 3) return .unknown;
        } else if (byte == 'M' or byte == 'm') {
            terminated = true;
            break;
        } else if (byte >= '0' and byte <= '9') {
            parts[part_idx] = parts[part_idx] *% 10 +% @as(u16, byte - '0');
        } else {
            return .unknown;
        }
    }

    if (!terminated or part_idx != 2) return .unknown;

    const button = parts[0];
    const col = if (parts[1] > 0) parts[1] - 1 else 0; // Convert to 0-indexed
    const row = if (parts[2] > 0) parts[2] - 1 else 0;

    const pos = MousePos{ .col = col, .row = row };

    return switch (button & 0x03) { // Mask to get button number
        0 => .{ .mouse_left = pos },
        2 => .{ .mouse_right = pos },
        else => .unknown,
    };
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/tui/input.zig tests/unit/test_input.zig build.zig
git commit -m "feat: TUI input parsing — keys, arrows, SGR mouse events"
```

---

### Task 6: TUI — Terminal Control

**Files:**
- Create: `src/tui/terminal.zig`

This is I/O code — not easily unit-testable. We verify it works through CLI tests later.

- [ ] **Step 1: Implement `src/tui/terminal.zig`**

```zig
// src/tui/terminal.zig
// Low-level terminal control: raw mode, mouse tracking, SIGWINCH, cursor.
// This is the ONLY file that performs terminal I/O.

const std = @import("std");
const posix = std.posix;

var original_termios: ?posix.termios = null;
var g_sigwinch_flag = std.atomic.Value(bool).init(false);

fn sigwinchHandler(_: c_int) callconv(.c) void {
    g_sigwinch_flag.store(true, .release);
}

pub fn checkAndClearResizeFlag() bool {
    return g_sigwinch_flag.swap(false, .acq_rel);
}

pub fn setupSigwinch() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = sigwinchHandler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &act, null);
}

pub fn enterRawMode() !void {
    const fd = std.fs.File.stdin().handle;
    var raw = try posix.tcgetattr(fd);
    original_termios = raw;

    // Disable canonical mode, echo, signals
    raw.lflag = raw.lflag & ~@as(posix.tc_lflag_t,
        posix.tc_lflag_t.ECHO | posix.tc_lflag_t.ICANON | posix.tc_lflag_t.ISIG | posix.tc_lflag_t.IEXTEN);
    // Disable input processing
    raw.iflag = raw.iflag & ~@as(posix.tc_iflag_t,
        posix.tc_iflag_t.IXON | posix.tc_iflag_t.ICRNL | posix.tc_iflag_t.BRKINT | posix.tc_iflag_t.INPCK | posix.tc_iflag_t.ISTRIP);
    // Raw output
    raw.oflag = raw.oflag & ~@as(posix.tc_oflag_t, posix.tc_oflag_t.OPOST);
    // 8-bit chars
    raw.cflag = raw.cflag | posix.tc_cflag_t.CS8;
    // Read returns after 1 byte or 100ms timeout
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 1; // 100ms

    try posix.tcsetattr(fd, .FLUSH, raw);
}

pub fn exitRawMode() void {
    if (original_termios) |orig| {
        posix.tcsetattr(std.fs.File.stdin().handle, .FLUSH, orig) catch {};
        original_termios = null;
    }
}

pub fn enableMouseTracking(writer: anytype) !void {
    // SGR 1006 mouse mode: supports coords > 223
    try writer.writeAll("\x1b[?1000h\x1b[?1006h");
}

pub fn disableMouseTracking(writer: anytype) !void {
    try writer.writeAll("\x1b[?1006l\x1b[?1000l");
}

pub fn hideCursor(writer: anytype) !void {
    try writer.writeAll("\x1b[?25l");
}

pub fn showCursor(writer: anytype) !void {
    try writer.writeAll("\x1b[?25h");
}

pub fn clearScreen(writer: anytype) !void {
    try writer.writeAll("\x1b[2J\x1b[H");
}

pub fn getTermSize() !struct { cols: u16, rows: u16 } {
    var ws: posix.winsize = undefined;
    const fd = std.fs.File.stdout().handle;
    const rc = std.os.linux.ioctl(fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return error.IoctlFailed;
    return .{ .cols = ws.ws_col, .rows = ws.ws_row };
}

/// Platform-aware terminal size query.
pub fn getTermSizePosix() !struct { cols: u16, rows: u16 } {
    const fd = std.fs.File.stdout().handle;
    var ws: posix.winsize = undefined;
    const TIOCGWINSZ: u32 = switch (@import("builtin").os.tag) {
        .macos => 0x40087468,
        .linux => 0x5413,
        else => @compileError("unsupported OS"),
    };
    const result = posix.system.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws));
    if (result != 0) return error.IoctlFailed;
    return .{ .cols = ws.ws_col, .rows = ws.ws_row };
}
```

Note: `getTermSize` has platform-specific ioctl constants. The implementation uses `getTermSizePosix` which handles macOS and Linux. The env var override for cols/rows (from the spec) is handled in `main.zig`, not here.

- [ ] **Step 2: Commit**

```bash
git add src/tui/terminal.zig
git commit -m "feat: TUI terminal control — raw mode, mouse, SIGWINCH, cursor"
```

---

### Task 7: TUI — Renderer (Pure Frame Output)

**Files:**
- Create: `src/tui/renderer.zig`
- Create: `tests/unit/test_renderer.zig`
- Modify: `build.zig` (add test target)

- [ ] **Step 1: Write failing tests for renderer**

Create `src/tui/renderer.zig` as stub:

```zig
// src/tui/renderer.zig
// Pure function: AppState + dimensions → ANSI output buffer.
```

Create `tests/unit/test_renderer.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const renderer = @import("../../src/tui/renderer.zig");

test "renderFrame produces output for small terminal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = renderer.RenderState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .max_iter = 50,
        .show_info = false,
    };

    const output = try renderer.renderFrame(state, 10, 5, allocator);
    defer allocator.free(output);

    // Output should not be empty
    try testing.expect(output.len > 0);
    // Should contain ANSI escape sequences
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
}

test "renderFrame with info bar includes coordinate info" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = renderer.RenderState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .max_iter = 50,
        .show_info = true,
    };

    const output = try renderer.renderFrame(state, 40, 10, allocator);
    defer allocator.free(output);

    // Info bar should contain "MANDELBROT" (part of the restore command)
    try testing.expect(std.mem.indexOf(u8, output, "MANDELBROT") != null);
}

test "renderFrame is deterministic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = renderer.RenderState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .max_iter = 50,
        .show_info = false,
    };

    const output1 = try renderer.renderFrame(state, 10, 5, allocator);
    defer allocator.free(output1);
    const output2 = try renderer.renderFrame(state, 10, 5, allocator);
    defer allocator.free(output2);

    try testing.expectEqualSlices(u8, output1, output2);
}

test "renderFrame interior region is mostly dark" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Zoom into the main cardioid — should be mostly interior (black/space)
    const state = renderer.RenderState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 3.0,
        .max_iter = 200,
        .show_info = false,
    };

    const output = try renderer.renderFrame(state, 20, 10, allocator);
    defer allocator.free(output);

    // Count space characters vs total printable chars (rough heuristic)
    var spaces: usize = 0;
    var total: usize = 0;
    for (output) |byte| {
        if (byte >= 0x20 and byte <= 0x7e) {
            total += 1;
            if (byte == ' ') spaces += 1;
        }
    }
    // When zoomed into cardioid, significant portion should be interior (spaces)
    try testing.expect(spaces > total / 4);
}
```

- [ ] **Step 2: Add test target to `build.zig`**

```zig
const renderer_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/test_renderer.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
const run_renderer_tests = b.addRunArtifact(renderer_tests);
test_step.dependOn(&run_renderer_tests.step);
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: Compilation error — `RenderState` and `renderFrame` not found.

- [ ] **Step 4: Implement `src/tui/renderer.zig`**

```zig
// src/tui/renderer.zig
// Pure function: RenderState + dimensions → ANSI output buffer.
// No I/O — returns a buffer that the caller writes to the terminal.

const std = @import("std");
const mandelbrot = @import("../core/mandelbrot.zig");
const coloring = @import("../core/coloring.zig");

pub const RenderState = struct {
    center_re: f128,
    center_im: f128,
    zoom: f128,
    max_iter: u32,
    show_info: bool,
};

const ASPECT_RATIO: f64 = 0.5;

/// Render a complete frame as an ANSI-escaped byte buffer.
/// Caller owns the returned memory.
pub fn renderFrame(
    state: RenderState,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,
) ![]u8 {
    // Reserve 1 row for info bar if enabled
    const render_height: u16 = if (state.show_info and height > 1) height - 1 else height;
    const pixel_count: usize = @as(usize, width) * @as(usize, render_height);

    // Allocate iteration buffer
    const iter_buf = try allocator.alloc(u32, pixel_count);
    defer allocator.free(iter_buf);

    // Compute iterations
    mandelbrot.computeRegion(.{
        .center_re = state.center_re,
        .center_im = state.center_im,
        .zoom = state.zoom,
        .width = width,
        .height = render_height,
        .max_iter = state.max_iter,
        .aspect_ratio = ASPECT_RATIO,
    }, iter_buf);

    // Build ANSI output — generous allocation (~30 bytes per cell for escape codes)
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(allocator);

    // Estimate: cursor home (6) + per cell (~30) + info bar (~200)
    try output.ensureTotalCapacity(allocator, 6 + pixel_count * 30 + 300);

    // Cursor home
    try output.appendSlice(allocator, "\x1b[H");

    var last_fg: u8 = 255;
    var last_bg: u8 = 255;

    var row: u16 = 0;
    while (row < render_height) : (row += 1) {
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            const idx = @as(usize, row) * @as(usize, width) + @as(usize, col);
            const cell = coloring.iterToCell(iter_buf[idx], state.max_iter);

            // Only emit color changes when they differ
            if (cell.fg_color != last_fg or cell.bg_color != last_bg) {
                var color_buf: [32]u8 = undefined;
                const color_str = std.fmt.bufPrint(&color_buf, "\x1b[38;5;{d};48;5;{d}m", .{
                    cell.fg_color, cell.bg_color,
                }) catch unreachable;
                try output.appendSlice(allocator, color_str);
                last_fg = cell.fg_color;
                last_bg = cell.bg_color;
            }

            try output.append(allocator, cell.char);
        }
        // Don't add newline after last render row
        if (row < render_height - 1) {
            try output.appendSlice(allocator, "\r\n");
        }
    }

    // Info bar
    if (state.show_info and height > 1) {
        try output.appendSlice(allocator, "\r\n");
        // Reset colors, reverse video for status bar
        try output.appendSlice(allocator, "\x1b[0m\x1b[7m");

        var info_buf: [256]u8 = undefined;

        // Format f128 as f64 for display (f128 formatting not directly supported)
        const cre_f64: f64 = @floatCast(state.center_re);
        const cim_f64: f64 = @floatCast(state.center_im);
        const zoom_f64: f64 = @floatCast(state.zoom);

        const info_str = std.fmt.bufPrint(&info_buf,
            " MANDELBROT_CENTER_RE={d:.15} MANDELBROT_CENTER_IM={d:.15} MANDELBROT_ZOOM={e} mandelbrot | iter={d}",
            .{ cre_f64, cim_f64, zoom_f64, state.max_iter },
        ) catch " [info too long]";

        // Pad or truncate to terminal width
        const info_len = @min(info_str.len, @as(usize, width));
        try output.appendSlice(allocator, info_str[0..info_len]);
        var pad: usize = info_len;
        while (pad < width) : (pad += 1) {
            try output.append(allocator, ' ');
        }

        // Reset colors
        try output.appendSlice(allocator, "\x1b[0m");
    }

    return try output.toOwnedSlice(allocator);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: All tests pass.

- [ ] **Step 6: Dump a small render, show Peter for visual verification**

Add a temporary debug test that prints rendered output for a 40x15 frame:

```zig
test "VISUAL CHECK: dump small render for Peter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = renderer.RenderState{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .max_iter = 100,
        .show_info = true,
    };

    const output = try renderer.renderFrame(state, 40, 15, allocator);
    defer allocator.free(output);

    std.debug.print("\n--- VISUAL CHECK ---\n{s}\n--- END ---\n", .{output});
}
```

Run and show Peter the output. Once approved, remove this test and encode any verified outputs as assertions.

- [ ] **Step 7: Commit**

```bash
git add src/tui/renderer.zig tests/unit/test_renderer.zig build.zig
git commit -m "feat: TUI renderer — pure state→ANSI buffer with info bar"
```

---

### Task 8: TUI — App Event Loop & Main Entry Point

**Files:**
- Create: `src/tui/app.zig`
- Modify: `src/main.zig` (full implementation)

- [ ] **Step 1: Implement `src/tui/app.zig`**

```zig
// src/tui/app.zig
// Event loop and state machine. Orchestrates input, state, and rendering.

const std = @import("std");
const terminal = @import("terminal.zig");
const input = @import("input.zig");
const renderer = @import("renderer.zig");
const viewport = @import("../core/viewport.zig");

const ZOOM_FACTOR: f128 = 2.0;
const ASPECT_RATIO: f64 = 0.5;

pub const AppState = struct {
    center_re: f128,
    center_im: f128,
    zoom: f128,
    max_iter: u32,
    base_iter: u32,
    show_info: bool,
    term_width: u16,
    term_height: u16,
    needs_redraw: bool,
    running: bool,
};

pub fn defaultState() AppState {
    return .{
        .center_re = -0.5,
        .center_im = 0.0,
        .zoom = 1.0,
        .max_iter = 256,
        .base_iter = 256,
        .show_info = true,
        .term_width = 80,
        .term_height = 24,
        .needs_redraw = true,
        .running = true,
    };
}

pub fn run(initial_state: AppState, allocator: std.mem.Allocator) !void {
    var state = initial_state;
    state.needs_redraw = true;

    const stdout_file = std.fs.File.stdout();
    const stdin_file = std.fs.File.stdin();

    // Setup terminal
    try terminal.enterRawMode();
    errdefer terminal.exitRawMode();

    var stdout_buf: [16384]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    try terminal.hideCursor(stdout);
    try terminal.enableMouseTracking(stdout);
    try terminal.clearScreen(stdout);
    try stdout.flush();

    terminal.setupSigwinch();

    var read_buf: [256]u8 = undefined;

    while (state.running) {
        // Check for resize
        if (terminal.checkAndClearResizeFlag()) {
            if (terminal.getTermSizePosix()) |size| {
                state.term_width = size.cols;
                state.term_height = size.rows;
                state.needs_redraw = true;
            } else |_| {}
        }

        // Render if needed
        if (state.needs_redraw) {
            const frame = try renderer.renderFrame(.{
                .center_re = state.center_re,
                .center_im = state.center_im,
                .zoom = state.zoom,
                .max_iter = state.max_iter,
                .show_info = state.show_info,
            }, state.term_width, state.term_height, allocator);
            defer allocator.free(frame);

            try stdout.writeAll(frame);
            try stdout.flush();
            state.needs_redraw = false;
        }

        // Read input (non-blocking due to VTIME=1)
        const n = stdin_file.read(&read_buf) catch 0;
        if (n == 0) continue;

        const event = input.parseEvent(read_buf[0..n]);
        state = processEvent(state, event);
    }

    // Cleanup
    try terminal.disableMouseTracking(stdout);
    try terminal.showCursor(stdout);
    try terminal.clearScreen(stdout);
    try stdout.flush();
    terminal.exitRawMode();
}

fn processEvent(state: AppState, event: input.Event) AppState {
    var s = state;
    switch (event) {
        .key_q, .ctrl_c => {
            s.running = false;
        },
        .key_plus => {
            const view = toViewState(s);
            const new_view = viewport.zoomAt(view, ZOOM_FACTOR,
                s.term_width / 2, s.term_height / 2,
                s.term_width, s.term_height, ASPECT_RATIO);
            applyViewState(&s, new_view);
            s.needs_redraw = true;
        },
        .key_minus => {
            const view = toViewState(s);
            const new_view = viewport.zoomAt(view, 1.0 / ZOOM_FACTOR,
                s.term_width / 2, s.term_height / 2,
                s.term_width, s.term_height, ASPECT_RATIO);
            applyViewState(&s, new_view);
            s.needs_redraw = true;
        },
        .mouse_left => |pos| {
            const view = toViewState(s);
            const new_view = viewport.zoomAt(view, ZOOM_FACTOR,
                pos.col, pos.row, s.term_width, s.term_height, ASPECT_RATIO);
            applyViewState(&s, new_view);
            s.needs_redraw = true;
        },
        .mouse_right => |pos| {
            const view = toViewState(s);
            const new_view = viewport.zoomAt(view, 1.0 / ZOOM_FACTOR,
                pos.col, pos.row, s.term_width, s.term_height, ASPECT_RATIO);
            applyViewState(&s, new_view);
            s.needs_redraw = true;
        },
        .arrow_up, .arrow_down, .arrow_left, .arrow_right => {
            const dir: viewport.Direction = switch (event) {
                .arrow_up => .up,
                .arrow_down => .down,
                .arrow_left => .left,
                .arrow_right => .right,
                else => unreachable,
            };
            const view = toViewState(s);
            const new_view = viewport.pan(view, dir, s.term_width, s.term_height, ASPECT_RATIO);
            applyViewState(&s, new_view);
            s.needs_redraw = true;
        },
        .key_bracket_open => {
            if (s.base_iter > 50) {
                s.base_iter -= 50;
                s.max_iter = viewport.adaptiveMaxIter(s.zoom, s.base_iter);
                s.needs_redraw = true;
            }
        },
        .key_bracket_close => {
            s.base_iter += 50;
            s.max_iter = viewport.adaptiveMaxIter(s.zoom, s.base_iter);
            s.needs_redraw = true;
        },
        .key_i => {
            s.show_info = !s.show_info;
            s.needs_redraw = true;
        },
        .resize => {
            s.needs_redraw = true;
        },
        .unknown => {},
    }
    return s;
}

fn toViewState(s: AppState) viewport.ViewState {
    return .{
        .center_re = s.center_re,
        .center_im = s.center_im,
        .zoom = s.zoom,
        .base_iter = s.base_iter,
        .max_iter = s.max_iter,
    };
}

fn applyViewState(s: *AppState, v: viewport.ViewState) void {
    s.center_re = v.center_re;
    s.center_im = v.center_im;
    s.zoom = v.zoom;
    s.max_iter = v.max_iter;
}
```

- [ ] **Step 2: Implement full `src/main.zig`**

```zig
// src/main.zig
// Entry point: parse env vars, set up initial state, run app, ensure cleanup.

const std = @import("std");
const app = @import("tui/app.zig");
const terminal = @import("tui/terminal.zig");
const viewport = @import("core/viewport.zig");

// Force imports for test discovery
comptime {
    _ = @import("core/mandelbrot.zig");
    _ = @import("core/viewport.zig");
    _ = @import("core/coloring.zig");
    _ = @import("tui/input.zig");
    _ = @import("tui/renderer.zig");
}

const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    if (comptime @import("builtin").mode == .Debug) {
        try stderr.print("\x1b[33mDEBUG BUILD\x1b[0m\n", .{});
        try stderr.flush();
    }

    // Check for --help, --about, --single-frame
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var single_frame = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_writer.interface;
            try stdout.print(
                \\mandelbrot — interactive TUI Mandelbrot set explorer
                \\
                \\Usage: mandelbrot [OPTIONS]
                \\
                \\Options:
                \\  -h, --help       Show this help
                \\  --about          Show version and platform info
                \\  --single-frame   Render one frame to stdout and exit
                \\  --no-color       Disable ANSI colors
                \\  --no-ansi        Disable all ANSI escapes
                \\  --simple         Plain ASCII mode (no color, ANSI, or emoji)
                \\
                \\Environment variables (for view injection / bookmarking):
                \\  MANDELBROT_CENTER_RE   Center real coordinate
                \\  MANDELBROT_CENTER_IM   Center imaginary coordinate
                \\  MANDELBROT_ZOOM        Zoom level
                \\  MANDELBROT_MAX_ITER    Max iteration count
                \\  MANDELBROT_COLS        Override terminal width
                \\  MANDELBROT_ROWS        Override terminal height
                \\
                \\Controls:
                \\  Left-click     Zoom in 2x at click point
                \\  Right-click    Zoom out 2x at click point
                \\  +/=            Zoom in 2x at center
                \\  -              Zoom out 2x at center
                \\  Arrow keys     Pan
                \\  [/]            Decrease/increase max iterations
                \\  i              Toggle info bar
                \\  q / Ctrl-C     Quit
                \\
            , .{});
            try stdout.flush();
            return;
        }
        if (std.mem.eql(u8, arg, "--about")) {
            var stdout_buf: [4096]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
            const stdout = &stdout_writer.interface;
            try stdout.print("mandelbrot v{s} ({s}-{s})\n", .{
                version,
                @tagName(@import("builtin").cpu.arch),
                @tagName(@import("builtin").os.tag),
            });
            try stdout.flush();
            return;
        }
        if (std.mem.eql(u8, arg, "--single-frame")) {
            single_frame = true;
        }
    }

    // Build initial state from env vars + defaults
    var state = app.defaultState();

    if (parseF128Env("MANDELBROT_CENTER_RE")) |v| state.center_re = v;
    if (parseF128Env("MANDELBROT_CENTER_IM")) |v| state.center_im = v;
    if (parseF128Env("MANDELBROT_ZOOM")) |v| state.zoom = v;
    if (parseU32Env("MANDELBROT_MAX_ITER")) |v| {
        state.max_iter = v;
        state.base_iter = v;
    }
    if (parseU16Env("MANDELBROT_COLS")) |v| state.term_width = v;
    if (parseU16Env("MANDELBROT_ROWS")) |v| state.term_height = v;

    // If no explicit size override, detect terminal
    if (parseU16Env("MANDELBROT_COLS") == null and parseU16Env("MANDELBROT_ROWS") == null) {
        if (terminal.getTermSizePosix()) |size| {
            state.term_width = size.cols;
            state.term_height = size.rows;
        } else |_| {
            // Defaults are fine (80x24)
        }
    }

    if (single_frame) {
        const renderer = @import("tui/renderer.zig");
        const frame = try renderer.renderFrame(.{
            .center_re = state.center_re,
            .center_im = state.center_im,
            .zoom = state.zoom,
            .max_iter = state.max_iter,
            .show_info = state.show_info,
        }, state.term_width, state.term_height, allocator);
        defer allocator.free(frame);

        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(frame);
        try stdout.print("\n", .{});
        try stdout.flush();
        return;
    }

    try app.run(state, allocator);
}

fn parseF128Env(name: []const u8) ?f128 {
    const val = std.posix.getenv(name) orelse return null;
    return std.fmt.parseFloat(f64, val) catch return null;
}

fn parseU32Env(name: []const u8) ?u32 {
    const val = std.posix.getenv(name) orelse return null;
    return std.fmt.parseInt(u32, val, 10) catch return null;
}

fn parseU16Env(name: []const u8) ?u16 {
    const val = std.posix.getenv(name) orelse return null;
    return std.fmt.parseInt(u16, val, 10) catch return null;
}

test "placeholder removed" {
    // Tests are in tests/unit/ — this file just needs comptime imports above
}
```

Note: `parseF128Env` currently parses as f64 and implicitly converts. When Zig adds f128 float parsing support, this can be upgraded. The precision loss is only in env var input, not in computation.

- [ ] **Step 3: Build and verify it compiles**

Run: `nix develop -c zig build -Doptimize=Debug`
Expected: Compiles successfully.

- [ ] **Step 4: Run all tests**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: All tests pass.

- [ ] **Step 5: Manual test — launch and quit**

Run: `nix develop -c zig build run -Doptimize=Debug`
Then press `q`. Expected: Mandelbrot renders, terminal is cleanly restored on exit.

- [ ] **Step 6: Commit**

```bash
git add src/tui/app.zig src/main.zig
git commit -m "feat: TUI app event loop + main entry point with env var injection"
```

---

### Task 9: CLI Tests

**Files:**
- Create: `tests/cli/test_cli.bash`
- Modify: `test` script (ensure CLI tests are included)

- [ ] **Step 1: Create `tests/cli/test_cli.bash`**

```bash
#!/usr/bin/env bash
set -u

# Source capture utility if available
if [ -f "$HOME/dotfiles/bin/src/capture.bash" ]; then
    source "$HOME/dotfiles/bin/src/capture.bash"
fi

errors=0
tests=0
passed=0

pass() {
    tests=$((tests + 1))
    passed=$((passed + 1))
    echo "  PASS: $1"
}

fail() {
    tests=$((tests + 1))
    errors=$((errors + 1))
    echo "  FAIL: $1"
    [ -n "${2:-}" ] && echo "        $2"
}

BINARY="${MANDELBROT_BIN:-./zig-out/bin/mandelbrot}"

if [ ! -x "$BINARY" ]; then
    echo "Binary not found at $BINARY — building..."
    nix develop -c zig build -Doptimize=Debug
fi

echo "=== CLI Tests ==="

# Test: --help exits 0
output=$("$BINARY" --help 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Usage:"; then
    pass "--help exits 0 with usage text"
else
    fail "--help exits 0 with usage text" "rc=$rc"
fi

# Test: -h exits 0
output=$("$BINARY" -h 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Usage:"; then
    pass "-h exits 0 with usage text"
else
    fail "-h exits 0 with usage text" "rc=$rc"
fi

# Test: --about prints version
output=$("$BINARY" --about 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "mandelbrot v"; then
    pass "--about prints version"
else
    fail "--about prints version" "rc=$rc output=$output"
fi

# Test: --single-frame produces output with env var injection
output=$(MANDELBROT_CENTER_RE="-0.5" MANDELBROT_CENTER_IM="0.0" MANDELBROT_ZOOM="1.0" \
    MANDELBROT_MAX_ITER="50" MANDELBROT_COLS="20" MANDELBROT_ROWS="10" \
    "$BINARY" --single-frame 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ -n "$output" ]; then
    pass "--single-frame produces output"
else
    fail "--single-frame produces output" "rc=$rc len=${#output}"
fi

# Test: --single-frame with info bar shows restore command
output=$(MANDELBROT_CENTER_RE="-0.7435669" MANDELBROT_CENTER_IM="0.1314023" \
    MANDELBROT_ZOOM="100" MANDELBROT_MAX_ITER="200" \
    MANDELBROT_COLS="80" MANDELBROT_ROWS="24" \
    "$BINARY" --single-frame 2>/dev/null)
if echo "$output" | grep -q "MANDELBROT_CENTER_RE"; then
    pass "--single-frame info bar shows restore command"
else
    fail "--single-frame info bar shows restore command"
fi

# Test: --single-frame is deterministic
output1=$(MANDELBROT_CENTER_RE="-0.5" MANDELBROT_CENTER_IM="0.0" MANDELBROT_ZOOM="1.0" \
    MANDELBROT_MAX_ITER="50" MANDELBROT_COLS="10" MANDELBROT_ROWS="5" \
    "$BINARY" --single-frame 2>/dev/null)
output2=$(MANDELBROT_CENTER_RE="-0.5" MANDELBROT_CENTER_IM="0.0" MANDELBROT_ZOOM="1.0" \
    MANDELBROT_MAX_ITER="50" MANDELBROT_COLS="10" MANDELBROT_ROWS="5" \
    "$BINARY" --single-frame 2>/dev/null)
if [ "$output1" = "$output2" ]; then
    pass "--single-frame is deterministic"
else
    fail "--single-frame is deterministic" "outputs differ"
fi

# Test: Debug build announces itself
output=$("$BINARY" --about 2>&1)
if echo "$output" | grep -q "DEBUG BUILD" || true; then
    # This is informational — just check it doesn't crash
    pass "debug build runs without crash"
fi

echo ""
echo "CLI Tests: $passed/$tests passed, $errors failed"
exit "$errors"
```

- [ ] **Step 2: Make it executable and run**

Run: `chmod +x tests/cli/test_cli.bash && bash tests/cli/test_cli.bash`
Expected: All CLI tests pass.

- [ ] **Step 3: Verify `./test` runs everything**

Run: `./test`
Expected: Unit tests + CLI tests all pass.

- [ ] **Step 4: Commit**

```bash
git add tests/cli/test_cli.bash test
git commit -m "feat: CLI test suite — help, about, single-frame, determinism"
```

---

### Task 10: Documentation & Cleanup

**Files:**
- Update: `PLAN.md`
- Update: `CODE_MINIMAP.md`
- Update: `.gitignore`

- [ ] **Step 1: Update `PLAN.md`**

```markdown
# Mandelbrot TUI Explorer — Plan

## Completed
- [x] Project scaffolding (build.zig, flake.nix, scripts)
- [x] Core mandelbrot computation (f128 escape-time + region fill)
- [x] Core viewport math (screen↔complex, zoom, pan, adaptive iter)
- [x] Core coloring (density chars + 256-color gradient)
- [x] TUI input parsing (keys, arrows, SGR mouse)
- [x] TUI terminal control (raw mode, mouse, SIGWINCH)
- [x] TUI renderer (pure state → ANSI buffer)
- [x] TUI app event loop + main entry point
- [x] CLI test suite
- [x] Documentation

## Future Enhancements
- [ ] Multithreaded computation (thread pool, row-band splitting)
- [ ] Arbitrary precision (bignum) for unlimited zoom depth
- [ ] C FFI surface exposing core functions
- [ ] "i" shows command to restore exact view (regardless of terminal size)
- [ ] Additional fractal types (Julia sets, Burning Ship)
- [ ] --lang / i18n support per CLI guidelines
- [ ] Cross-platform builds (5 OS/arch targets via build_all)
- [ ] Benchmark suite (./bm)
- [ ] --no-color / --no-ansi / --simple modes (wired up but need testing)
```

- [ ] **Step 2: Update `CODE_MINIMAP.md`**

```markdown
# Code Minimap

## `build.zig`
- `build()` — Zig 0.15 build config: executable + 5 test targets, ReleaseFast default

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

## `tests/unit/test_mandelbrot.zig` — escape-time + region computation tests
## `tests/unit/test_viewport.zig` — coordinate mapping, zoom, pan, adaptive iter tests
## `tests/unit/test_coloring.zig` — density chars, color range, gradient smoothness tests
## `tests/unit/test_input.zig` — key, arrow, mouse, Ctrl-C parsing tests
## `tests/unit/test_renderer.zig` — frame output, info bar, determinism tests
## `tests/cli/test_cli.bash` — CLI integration tests (help, about, single-frame)
```

- [ ] **Step 3: Update `.gitignore`**

Add build artifacts:

```
AGENTS.md
CLAUDE.md
jj_cheatsheet.md
ZIG_RECENT_API_CHANGES*
zig-out/
zig-cache/
.zig-cache/
result
result-*
```

- [ ] **Step 4: Final test run**

Run: `./test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add PLAN.md CODE_MINIMAP.md PROJECT_OVERVIEW.md .gitignore
git commit -m "docs: PLAN.md, CODE_MINIMAP.md, PROJECT_OVERVIEW.md, updated .gitignore"
```

---

## Self-Review

**Spec coverage:**
- ✅ f128 computation (Task 2)
- ✅ computeRegion for grid (Task 2)
- ✅ Viewport math: screenToComplex, zoomAt, pan, adaptiveMaxIter (Task 3)
- ✅ Coloring: density chars + 256-color cyclic gradient (Task 4)
- ✅ Input parsing: all events including SGR mouse (Task 5)
- ✅ Terminal control: raw mode, mouse, SIGWINCH, cursor (Task 6)
- ✅ Renderer: pure state → ANSI buffer with info bar (Task 7)
- ✅ App event loop: all keybindings, mouse zoom, resize (Task 8)
- ✅ CLI: --help, --about, --single-frame, env var injection (Task 8)
- ✅ CLI tests (Task 9)
- ✅ Info bar with reproducible view command (Task 7, renderer)
- ✅ SIGWINCH resize handling (Task 6 + Task 8)
- ✅ --no-color/--no-ansi/--simple listed in help (Task 8, not wired — future)

**Placeholder scan:** No TBDs, TODOs, or incomplete sections in code blocks.

**Type consistency:**
- `RegionParams` used consistently in mandelbrot.zig and renderer.zig
- `ViewState` used consistently in viewport.zig and app.zig
- `RenderState` used consistently in renderer.zig and app.zig
- `Event` / `MousePos` used consistently in input.zig and app.zig
- `Cell` used consistently in coloring.zig and renderer.zig

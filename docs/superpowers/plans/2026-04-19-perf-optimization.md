# Performance Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Target 30-80x speedup on the Mandelbrot render hot path via thread count increase, interleaved row assignment, and f64 hot loop (f128 emulation is slow on Apple Silicon). Add benchmark infrastructure (`--bench-zoom-sequence` CLI flag, expanded microbenchmarks, regression detection) to measure and protect improvements.

**Architecture:** Keep `f128` for cumulative viewport state (precision across many pan/zoom ops) but use `f64` in the per-pixel iteration loop when zoom < 10^13. Make `computeIterations` comptime-generic over float type. Auto-detect thread count (cap 12). Replace contiguous row-bands with stride-interleaved assignment so all threads see similar work.

**Tech Stack:** Zig 0.15.2, `std.Thread`, `std.atomic.Value`, `hyperfine` for end-to-end timing.

**Spec:** `docs/superpowers/specs/2026-04-19-perf-optimization-design.md`

**IMPORTANT Zig 0.15 notes:**
- `std.Thread.spawn(.{}, fn, .{args})` returns `!std.Thread`
- `std.atomic.Value(T).init(v)`, `.load(.acquire)`, `.fetchAdd(n, .monotonic)`
- `@floatCast(x)` converts between float types
- `std.Thread.getCpuCount() !usize` returns logical CPU count
- `std.fs.File.stderr().writer(&buf)` then `&writer.interface` for buffered stderr

---

## File Structure

```
src/
  core/
    mandelbrot.zig       — MODIFY: add computeIterationsT, computeRowStride, autoThreadCount,
                           f64/f128 dispatch, test-only counters
  main.zig               — MODIFY: add --bench-zoom-sequence N and --bench-quiet flags
tests/
  unit/
    test_parallel.zig    — ADD: f64/f128 equivalence, thread variations, dispatch tests
  benchmark/
    bench_render.zig     — MODIFY: shallow/deep/sequence scenarios, thread count sweep
  cli/
    test_cli.bash        — ADD: --bench-zoom-sequence smoke test
bm                       — MODIFY: regression detection (>10% warning, non-fatal)
```

---

### Task 1: Expanded Microbenchmark Scenarios + `bm` Regression Detection

Establish measurement baseline BEFORE making any perf changes. That way each optimization's impact is visible in the log.

**Files:**
- Modify: `tests/benchmark/bench_render.zig`
- Modify: `bm`

- [ ] **Step 1: Rewrite `tests/benchmark/bench_render.zig` with shallow/deep/sequence scenarios**

Replace the entire file content with:

```zig
// tests/benchmark/bench_render.zig
// Benchmarks for Mandelbrot rendering: sequential vs parallel across three scenarios.
// Always runs in ReleaseFast — debug mode aborts with a loud error.

const std = @import("std");
const mandelbrot = @import("mandelbrot");

const BenchResult = struct {
	scenario: []const u8,
	width: u16,
	height: u16,
	max_iter: u32,
	zoom: f128,
	seq_ms: f64,
	par_ms: f64,
	speedup: f64,
};

fn benchmarkScenario(
	allocator: std.mem.Allocator,
	name: []const u8,
	params: mandelbrot.RegionParams,
	n_iters: u32,
) !BenchResult {
	const size: usize = @as(usize, params.width) * @as(usize, params.height);
	const buf_seq = try allocator.alloc(f64, size);
	defer allocator.free(buf_seq);
	const buf_par = try allocator.alloc(f64, size);
	defer allocator.free(buf_par);

	// Warm up
	mandelbrot.computeRegion(params, buf_seq);

	// Sequential
	var timer = try std.time.Timer.start();
	var i: u32 = 0;
	while (i < n_iters) : (i += 1) {
		mandelbrot.computeRegion(params, buf_seq);
	}
	const seq_ns = timer.read();

	// Parallel
	timer.reset();
	i = 0;
	while (i < n_iters) : (i += 1) {
		try mandelbrot.parallelComputeRegion(params, buf_par);
	}
	const par_ns = timer.read();

	// Correctness check
	if (!std.mem.eql(f64, buf_seq, buf_par)) {
		return error.ParallelMismatch;
	}

	const seq_ms = @as(f64, @floatFromInt(seq_ns)) / @as(f64, @floatFromInt(n_iters)) / 1_000_000.0;
	const par_ms = @as(f64, @floatFromInt(par_ns)) / @as(f64, @floatFromInt(n_iters)) / 1_000_000.0;

	return .{
		.scenario = name,
		.width = params.width,
		.height = params.height,
		.max_iter = params.max_iter,
		.zoom = params.zoom,
		.seq_ms = seq_ms,
		.par_ms = par_ms,
		.speedup = seq_ms / par_ms,
	};
}

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	if (comptime @import("builtin").mode == .Debug) {
		try stderr.writeAll("\x1b[31mERROR: bench-render must NOT run in Debug mode.\x1b[0m\n");
		try stderr.writeAll("Rebuild with: nix develop -c zig build bench\n");
		try stderr.flush();
		std.process.exit(1);
	}

	const N: u32 = 10;

	try stderr.writeAll("\n=== Mandelbrot Render Benchmarks ===\n\n");
	try stderr.flush();

	// Shallow: default view — mostly escape-velocity points, tests iteration throughput
	const shallow = try benchmarkScenario(allocator, "Shallow (zoom=1)", .{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 200,
		.height = 60,
		.max_iter = 256,
		.aspect_ratio = 0.5,
	}, N);

	// Deep: zoomed into the seahorse valley — many interior points, stresses max_iter
	const deep = try benchmarkScenario(allocator, "Deep (zoom=1000)", .{
		.center_re = -0.7435,
		.center_im = 0.1314,
		.zoom = 1000.0,
		.width = 200,
		.height = 60,
		.max_iter = 1000,
		.aspect_ratio = 0.5,
	}, N);

	// Small view — tests thread overhead on less work
	const small = try benchmarkScenario(allocator, "Small (80x24)", .{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 80,
		.height = 24,
		.max_iter = 256,
		.aspect_ratio = 0.5,
	}, N);

	const results = [_]BenchResult{ shallow, deep, small };
	for (results) |r| {
		try stderr.print("  {s}: {d}x{d}, iter={d}, zoom={d}, N={d}\n", .{
			r.scenario, r.width, r.height, r.max_iter, @as(f64, @floatCast(r.zoom)), N,
		});
		try stderr.print("    Sequential:  {d:.2} ms/frame\n", .{r.seq_ms});
		try stderr.print("    Parallel:    {d:.2} ms/frame\n", .{r.par_ms});
		try stderr.print("    Speedup:     {d:.2}x\n\n", .{r.speedup});
	}

	try stderr.flush();
}
```

- [ ] **Step 2: Rewrite `bm` script with regression detection**

Replace contents of `bm`:

```bash
#!/usr/bin/env bash
set -uo pipefail

mkdir -p benchmarks
LOGFILE="benchmarks/results.log"
TMP_OUT=$(mktemp)

# Capture the most recent run (if any) for comparison
PREV_RUN=""
if [ -f "$LOGFILE" ]; then
	# Extract the last run's "Speedup:" lines as a simple comparison surface
	PREV_RUN=$(awk '/^=== Benchmark run:/{buf=""} {buf=buf"\n"$0} END{print buf}' "$LOGFILE" | grep -E "Speedup:" || true)
fi

{
	echo ""
	echo "=== Benchmark run: $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
	echo "Git: $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"
	echo ""
} | tee -a "$LOGFILE"

nix develop -c zig build bench 2>&1 | tee "$TMP_OUT" | tee -a "$LOGFILE"

# Regression check: compare current speedups to previous run
if [ -n "$PREV_RUN" ]; then
	CUR_RUN=$(grep -E "Speedup:" "$TMP_OUT" || true)
	# Parse "Speedup: X.XXx" → float
	paste <(echo "$PREV_RUN") <(echo "$CUR_RUN") | while IFS=$'\t' read -r prev cur; do
		if [ -z "$prev" ] || [ -z "$cur" ]; then
			continue
		fi
		prev_val=$(echo "$prev" | grep -oE '[0-9]+\.[0-9]+')
		cur_val=$(echo "$cur" | grep -oE '[0-9]+\.[0-9]+')
		if [ -n "$prev_val" ] && [ -n "$cur_val" ]; then
			pct_change=$(awk -v p="$prev_val" -v c="$cur_val" 'BEGIN{printf "%.1f", (c-p)/p*100}')
			# Negative pct_change means slower (regression). Flag >10% regression.
			awk -v pct="$pct_change" -v p="$prev_val" -v c="$cur_val" 'BEGIN{
				if (pct+0 < -10) {
					printf "\033[31mREGRESSION: speedup %.2fx -> %.2fx (%.1f%% change)\033[0m\n", p, c, pct;
					exit 0;
				}
			}'
		fi
	done
fi

rm -f "$TMP_OUT"
```

Make it executable if not already: `chmod +x bm`

- [ ] **Step 3: Run baseline bench**

```
./bm
```

Expected: three scenarios print (Shallow, Deep, Small), each with sequential/parallel/speedup. Results append to `benchmarks/results.log`. No regression warning on first run (there's no prior run to compare to).

- [ ] **Step 4: Verify full test suite still passes**

```
./test
```

- [ ] **Step 5: Commit**

```bash
git add tests/benchmark/bench_render.zig bm benchmarks/results.log
git commit -m "feat: expand bench scenarios + bm regression detection (baseline)"
```

Do NOT include Co-Authored-By lines.

---

### Task 2: Thread Count Auto-Detection (Cap 12)

**Files:**
- Modify: `src/core/mandelbrot.zig`
- Modify: `src/tui/app.zig` (update call to `parallelComputeRegion`)
- Modify: `tests/unit/test_parallel.zig` (add thread count test)

- [ ] **Step 1: Write failing test for thread count parameter**

Append to `tests/unit/test_parallel.zig`:

```zig
test "parallelComputeRegion with explicit thread count produces identical output" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const params = mandelbrot.RegionParams{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 40,
		.height = 20,
		.max_iter = 100,
		.aspect_ratio = 0.5,
	};

	const size: usize = 40 * 20;
	const buf_ref = try allocator.alloc(f64, size);
	defer allocator.free(buf_ref);
	mandelbrot.computeRegion(params, buf_ref);

	// Test with 1, 2, 3, 4, 8 threads
	const thread_counts = [_]u32{ 1, 2, 3, 4, 8 };
	for (thread_counts) |n| {
		const buf = try allocator.alloc(f64, size);
		defer allocator.free(buf);
		try mandelbrot.parallelComputeRegion(params, buf, n);
		try testing.expectEqualSlices(f64, buf_ref, buf);
	}
}

test "autoThreadCount returns something sensible" {
	const n = mandelbrot.autoThreadCount();
	try testing.expect(n >= 1);
	try testing.expect(n <= 12);
}
```

- [ ] **Step 2: Run — should fail**

```
nix develop -c zig build test -Doptimize=Debug
```

Expected: "autoThreadCount not found" and "too few arguments to parallelComputeRegion".

- [ ] **Step 3: Update mandelbrot.zig — `parallelComputeRegion` takes optional thread count**

In `src/core/mandelbrot.zig`:

Replace:
```zig
/// Number of worker threads for parallel computation.
const NUM_THREADS: u32 = 3;
```

With:
```zig
/// Maximum number of worker threads we'll ever spawn.
/// Cap 12 to leave headroom for main thread + OS + other processes on many-core systems.
const MAX_THREADS: u32 = 12;

/// Detect optimal worker thread count for the current CPU.
/// Caps at MAX_THREADS. Returns 3 as a safe fallback if detection fails.
pub fn autoThreadCount() u32 {
	const count = std.Thread.getCpuCount() catch return 3;
	return @intCast(@min(@max(count, @as(usize, 1)), MAX_THREADS));
}
```

Replace the entire body of `parallelComputeRegion` with:

```zig
/// Parallel version of computeRegion. Splits rows across `num_threads` threads.
/// If `num_threads` is null, auto-detects. Output is identical to sequential.
/// Falls back to sequential for very small heights (< num_threads rows).
pub fn parallelComputeRegion(params: RegionParams, out: []f64, num_threads: ?u32) !void {
	const n = num_threads orelse autoThreadCount();
	const height = params.height;
	if (height < n or n <= 1) {
		computeRegion(params, out);
		return;
	}

	const rows_per_thread = height / n;
	var threads: [MAX_THREADS]std.Thread = undefined;
	var i: u32 = 0;
	while (i < n) : (i += 1) {
		const start_row: u16 = @intCast(i * rows_per_thread);
		const end_row: u16 = if (i == n - 1) height else @intCast((i + 1) * rows_per_thread);
		threads[i] = try std.Thread.spawn(.{}, computeRowBand, .{ params, out, start_row, end_row });
	}
	var j: u32 = 0;
	while (j < n) : (j += 1) {
		threads[j].join();
	}
}
```

- [ ] **Step 4: Update `src/tui/app.zig` to pass null (auto) for thread count**

Find the line (currently around line 136):
```zig
try mandelbrot.parallelComputeRegion(.{
    ...
}, iter_buf);
```

Change to:
```zig
try mandelbrot.parallelComputeRegion(.{
    ...
}, iter_buf, null);
```

- [ ] **Step 5: Update existing parallel tests in `tests/unit/test_parallel.zig`**

All existing `parallelComputeRegion(params, buf)` calls need a third argument. Add `null` to each:

```zig
try mandelbrot.parallelComputeRegion(params, parallel, null);
```

There should be 3 existing tests that call `parallelComputeRegion` (even/odd/small heights). Update each.

- [ ] **Step 6: Run tests — should pass**

```
nix develop -c zig build test -Doptimize=Debug
```

All 80+ tests should pass, including the new ones.

- [ ] **Step 7: Run bench and verify speedup improved**

```
./bm
```

Expected: ~3x-4x parallel speedup (up from 1.55x baseline). Auto-detects ~8 threads on M4 Max.

- [ ] **Step 8: Commit**

```bash
git add src/core/mandelbrot.zig src/tui/app.zig tests/unit/test_parallel.zig benchmarks/results.log
git commit -m "perf: auto-detect thread count (cap 12), up from hardcoded 3"
```

---

### Task 3: Interleaved Row Assignment (Load Balancing)

**Files:**
- Modify: `src/core/mandelbrot.zig`
- Modify: `tests/unit/test_parallel.zig`

- [ ] **Step 1: Write failing test for computeRowStride**

Append to `tests/unit/test_parallel.zig`:

```zig
test "computeRowStride produces same result as computeRegion" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const params = mandelbrot.RegionParams{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0,
		.width = 30,
		.height = 15,
		.max_iter = 100,
		.aspect_ratio = 0.5,
	};

	const size: usize = 30 * 15;
	const buf_ref = try allocator.alloc(f64, size);
	defer allocator.free(buf_ref);
	const buf_stride = try allocator.alloc(f64, size);
	defer allocator.free(buf_stride);

	mandelbrot.computeRegion(params, buf_ref);

	// Run 4 stride workers (each handling 1/4 of rows)
	@memset(buf_stride, 0.0);
	var thread_idx: u32 = 0;
	while (thread_idx < 4) : (thread_idx += 1) {
		mandelbrot.computeRowStride(params, buf_stride, thread_idx, 4);
	}

	try testing.expectEqualSlices(f64, buf_ref, buf_stride);
}
```

- [ ] **Step 2: Run — should fail**

Expected: "computeRowStride not found".

- [ ] **Step 3: Add `computeRowStride` alongside (not replacing yet) `computeRowBand`**

In `src/core/mandelbrot.zig`, add AFTER `computeRowBand`:

```zig
/// Compute rows with stride (interleaved) row assignment.
/// Thread `thread_idx` of `num_threads` total processes rows
/// `thread_idx, thread_idx + num_threads, thread_idx + 2*num_threads, ...`.
/// This balances load across threads: the fractal's high-iteration interior
/// gets spread across all threads instead of concentrating in one contiguous band.
pub fn computeRowStride(params: RegionParams, out: []f64, thread_idx: u32, num_threads: u32) void {
	const w: f128 = @floatFromInt(params.width);
	const h: f128 = @floatFromInt(params.height);
	const aspect: f128 = @floatCast(params.aspect_ratio);

	const range_re = 4.0 / params.zoom;
	const range_im = range_re * (h / w) / aspect;

	const step_re = range_re / w;
	const step_im = range_im / h;

	const start_re = params.center_re - range_re / 2.0;
	const start_im = params.center_im - range_im / 2.0;

	var row: u32 = thread_idx;
	while (row < params.height) : (row += num_threads) {
		var col: u32 = 0;
		while (col < params.width) : (col += 1) {
			const c_re = start_re + @as(f128, @floatFromInt(col)) * step_re;
			const c_im = start_im + @as(f128, @floatFromInt(row)) * step_im;
			const idx = row * @as(u32, params.width) + col;
			out[idx] = computeIterations(c_re, c_im, params.max_iter);
		}
	}
}
```

- [ ] **Step 4: Update `parallelComputeRegion` to use `computeRowStride`**

Replace the body of `parallelComputeRegion` again:

```zig
pub fn parallelComputeRegion(params: RegionParams, out: []f64, num_threads: ?u32) !void {
	const n = num_threads orelse autoThreadCount();
	const height = params.height;
	if (height < n or n <= 1) {
		computeRegion(params, out);
		return;
	}

	var threads: [MAX_THREADS]std.Thread = undefined;
	var i: u32 = 0;
	while (i < n) : (i += 1) {
		threads[i] = try std.Thread.spawn(.{}, computeRowStride, .{ params, out, i, n });
	}
	var j: u32 = 0;
	while (j < n) : (j += 1) {
		threads[j].join();
	}
}
```

- [ ] **Step 5: Delete now-unused `computeRowBand`**

Remove the `computeRowBand` function from `src/core/mandelbrot.zig`. It's replaced by `computeRowStride`.

- [ ] **Step 6: Run tests — should pass**

```
nix develop -c zig build test -Doptimize=Debug
```

- [ ] **Step 7: Run bench**

```
./bm
```

Expected: speedup jumps (likely to 5-8x on deep scenarios where load imbalance was worst). Shallow may improve less since it was already balanced.

- [ ] **Step 8: Commit**

```bash
git add src/core/mandelbrot.zig tests/unit/test_parallel.zig benchmarks/results.log
git commit -m "perf: stride-based row assignment eliminates load imbalance"
```

---

### Task 4: f64 Hot Loop (The Big One)

**Files:**
- Modify: `src/core/mandelbrot.zig`
- Modify: `tests/unit/test_parallel.zig`

- [ ] **Step 1: Write failing tests for f64/f128 equivalence and dispatch counters**

Append to `tests/unit/test_parallel.zig`:

```zig
test "computeIterations f64 matches computeIterationsF128 at shallow zoom" {
	// At shallow zoom, f64 and f128 paths must agree within a tight tolerance.
	// Smooth iteration count uses log-log-based floats; exact equality isn't expected
	// but they should agree within epsilon.
	const points = [_][2]f64{
		.{ 0.3, 0.5 },
		.{ -1.2, 0.1 },
		.{ 0.25, 0.35 },
		.{ -0.5, 0.6 },
		.{ 1.8, 0.0 },
		.{ -2.0, 0.0 },
		.{ 0.0, 1.0 },
		.{ -0.7435, 0.1314 },
	};
	for (points) |p| {
		const r_f64 = mandelbrot.computeIterations(p[0], p[1], 256);
		const r_f128 = mandelbrot.computeIterationsF128(
			@as(f128, p[0]),
			@as(f128, p[1]),
			256,
		);
		if (r_f64 == mandelbrot.INTERIOR) {
			try testing.expectEqual(mandelbrot.INTERIOR, r_f128);
		} else if (r_f128 == mandelbrot.INTERIOR) {
			try testing.expectEqual(mandelbrot.INTERIOR, r_f64);
		} else {
			try testing.expectApproxEqAbs(r_f64, r_f128, 1e-9);
		}
	}
}

test "f64 dispatch counter increments on shallow zoom" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	mandelbrot.resetDispatchCounters();

	const params = mandelbrot.RegionParams{
		.center_re = -0.5,
		.center_im = 0.0,
		.zoom = 1.0, // Well below threshold — should use f64
		.width = 20,
		.height = 10,
		.max_iter = 50,
		.aspect_ratio = 0.5,
	};
	const size: usize = 20 * 10;
	const buf = try allocator.alloc(f64, size);
	defer allocator.free(buf);

	mandelbrot.computeRowStride(params, buf, 0, 1);

	try testing.expect(mandelbrot.f64DispatchCount() > 0);
	try testing.expectEqual(@as(u64, 0), mandelbrot.f128DispatchCount());
}

test "f128 dispatch counter increments on deep zoom" {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	mandelbrot.resetDispatchCounters();

	const params = mandelbrot.RegionParams{
		.center_re = -0.7435,
		.center_im = 0.1314,
		.zoom = 1.0e14, // Above threshold (10^13) — should use f128
		.width = 20,
		.height = 10,
		.max_iter = 50,
		.aspect_ratio = 0.5,
	};
	const size: usize = 20 * 10;
	const buf = try allocator.alloc(f64, size);
	defer allocator.free(buf);

	mandelbrot.computeRowStride(params, buf, 0, 1);

	try testing.expect(mandelbrot.f128DispatchCount() > 0);
	try testing.expectEqual(@as(u64, 0), mandelbrot.f64DispatchCount());
}
```

- [ ] **Step 2: Run tests — should fail**

Expected: `computeIterationsF128` not found, `resetDispatchCounters`, `f64DispatchCount`, `f128DispatchCount` not found.

- [ ] **Step 3: Add comptime-generic computeIterationsT + wrappers + dispatch counters**

In `src/core/mandelbrot.zig`:

Replace the existing `computeIterations` function with:

```zig
/// Generic smooth iteration count over float type T (f64 or f128).
/// Returns f64 (smooth iteration count is always returned as f64 for storage).
/// Interior points return INTERIOR (-1.0).
pub fn computeIterationsT(comptime T: type, c_re: T, c_im: T, max_iter: u32) f64 {
	var z_re: T = 0.0;
	var z_im: T = 0.0;
	const bailout_sq: T = @as(T, BAILOUT_SQ_F64);
	var i: u32 = 0;
	while (i < max_iter) : (i += 1) {
		const z_re2 = z_re * z_re;
		const z_im2 = z_im * z_im;
		if (z_re2 + z_im2 > bailout_sq) {
			const mod_sq: f64 = @floatCast(z_re2 + z_im2);
			const log_zn = @log(mod_sq) / 2.0;
			const nu = @log(log_zn / @log(2.0)) / @log(2.0);
			return @as(f64, @floatFromInt(i)) + 1.0 - nu;
		}
		z_im = 2.0 * z_re * z_im + c_im;
		z_re = z_re2 - z_im2 + c_re;
	}
	return INTERIOR;
}

/// Default: fast f64 path. Safe to ~10^13 zoom depth (f64 relative precision
/// ~2.2e-16; pixel spacing at that zoom is ~0.02/10^13 ~ 2e-15 — still resolvable).
pub fn computeIterations(c_re: f64, c_im: f64, max_iter: u32) f64 {
	return computeIterationsT(f64, c_re, c_im, max_iter);
}

/// Precision path: use when zoom exceeds ~10^13.
pub fn computeIterationsF128(c_re: f128, c_im: f128, max_iter: u32) f64 {
	return computeIterationsT(f128, c_re, c_im, max_iter);
}
```

Also change the bailout constant near the top. Find:
```zig
const BAILOUT_SQ: f128 = 65536.0; // 256^2
```

Replace with:
```zig
/// Bailout squared. Stored as f64 so both f64 and f128 paths can coerce cleanly.
const BAILOUT_SQ_F64: f64 = 65536.0; // 256^2
```

Remove `const math = std.math;` if still present (unused).

- [ ] **Step 4: Add F128 dispatch threshold + test-only counters**

Add after the BAILOUT_SQ_F64 line:

```zig
/// Zoom threshold above which f128 precision is required.
/// Derived from f64's relative precision (2.2e-16) vs pixel spacing (4/zoom/width).
/// At zoom 10^13 on a 200-wide terminal, pixel spacing is ~2e-15 — close to f64's limit.
pub const F128_DISPATCH_THRESHOLD: f128 = 1.0e13;

/// Test-only dispatch counters. Incremented once per call to computeRowStride
/// and friends, not once per pixel. Let tests verify dispatch decisions.
var g_f64_dispatch = std.atomic.Value(u64).init(0);
var g_f128_dispatch = std.atomic.Value(u64).init(0);

pub fn resetDispatchCounters() void {
	g_f64_dispatch.store(0, .release);
	g_f128_dispatch.store(0, .release);
}

pub fn f64DispatchCount() u64 {
	return g_f64_dispatch.load(.acquire);
}

pub fn f128DispatchCount() u64 {
	return g_f128_dispatch.load(.acquire);
}
```

- [ ] **Step 5: Update `computeRowStride` to dispatch based on zoom**

Replace the body of `computeRowStride` with:

```zig
pub fn computeRowStride(params: RegionParams, out: []f64, thread_idx: u32, num_threads: u32) void {
	const w: f128 = @floatFromInt(params.width);
	const h: f128 = @floatFromInt(params.height);
	const aspect: f128 = @floatCast(params.aspect_ratio);

	const range_re = 4.0 / params.zoom;
	const range_im = range_re * (h / w) / aspect;

	const step_re = range_re / w;
	const step_im = range_im / h;

	const start_re = params.center_re - range_re / 2.0;
	const start_im = params.center_im - range_im / 2.0;

	// Dispatch decision: below threshold use f64 (fast on hardware),
	// above threshold use f128 (slow soft-float, but required for precision).
	if (params.zoom <= F128_DISPATCH_THRESHOLD) {
		_ = g_f64_dispatch.fetchAdd(1, .monotonic);
		// Precompute f64 versions of the row-invariant scalars for the inner loop
		const start_re_f64: f64 = @floatCast(start_re);
		const start_im_f64: f64 = @floatCast(start_im);
		const step_re_f64: f64 = @floatCast(step_re);
		const step_im_f64: f64 = @floatCast(step_im);

		var row: u32 = thread_idx;
		while (row < params.height) : (row += num_threads) {
			const row_f64: f64 = @floatFromInt(row);
			const c_im_f64 = start_im_f64 + row_f64 * step_im_f64;
			var col: u32 = 0;
			while (col < params.width) : (col += 1) {
				const col_f64: f64 = @floatFromInt(col);
				const c_re_f64 = start_re_f64 + col_f64 * step_re_f64;
				const idx = row * @as(u32, params.width) + col;
				out[idx] = computeIterations(c_re_f64, c_im_f64, params.max_iter);
			}
		}
	} else {
		_ = g_f128_dispatch.fetchAdd(1, .monotonic);
		var row: u32 = thread_idx;
		while (row < params.height) : (row += num_threads) {
			var col: u32 = 0;
			while (col < params.width) : (col += 1) {
				const c_re = start_re + @as(f128, @floatFromInt(col)) * step_re;
				const c_im = start_im + @as(f128, @floatFromInt(row)) * step_im;
				const idx = row * @as(u32, params.width) + col;
				out[idx] = computeIterationsF128(c_re, c_im, params.max_iter);
			}
		}
	}
}
```

- [ ] **Step 6: Update `computeRegion` to use f64 path (consistent with parallelComputeRegion)**

Replace the body of `computeRegion` with:

```zig
pub fn computeRegion(params: RegionParams, out: []f64) void {
	// Use the stride path with thread_idx=0, num_threads=1 — iterates every row
	computeRowStride(params, out, 0, 1);
}
```

This ensures sequential and parallel paths produce bit-identical output because they share the same inner loop.

- [ ] **Step 7: Update `computeRegionDirect` and `offsetWorker` to dispatch based on step size**

For cache levels, zoom isn't stored directly. Use step size as the proxy: smaller step = deeper zoom. Threshold: `step_re < F128_STEP_THRESHOLD` (derived from f64 precision).

Add constant:
```zig
/// Step-size threshold below which f128 precision is required.
/// Complementary to F128_DISPATCH_THRESHOLD (zoom-based). Equivalent when
/// terminal is ~200 wide: step = 4/zoom/200, so step < 2e-15 ⇔ zoom > 1e13.
pub const F128_STEP_THRESHOLD: f128 = 2.0e-15;
```

Replace `computeRegionDirect` body with:

```zig
pub fn computeRegionDirect(level: *cache_mod.CacheLevel) void {
	if (level.step_re > F128_STEP_THRESHOLD) {
		// f64 path
		var row: u32 = 0;
		while (row < level.height) : (row += 1) {
			var col: u32 = 0;
			while (col < level.width) : (col += 1) {
				const pt = level.pointAt(col, row);
				const c_re: f64 = @floatCast(pt.re);
				const c_im: f64 = @floatCast(pt.im);
				level.set(col, row, computeIterations(c_re, c_im, level.max_iter));
			}
		}
	} else {
		// f128 path
		var row: u32 = 0;
		while (row < level.height) : (row += 1) {
			var col: u32 = 0;
			while (col < level.width) : (col += 1) {
				const pt = level.pointAt(col, row);
				level.set(col, row, computeIterationsF128(pt.re, pt.im, level.max_iter));
			}
		}
	}
	level.complete = true;
}
```

Replace `offsetWorker` body with:

```zig
fn offsetWorker(args: OffsetWorkerArgs) void {
	const use_f64 = args.child.step_re > F128_STEP_THRESHOLD;
	var row: u32 = args.row_start;
	while (row < args.child.height) : (row += 2) {
		if (args.gen) |g| {
			if (g.load(.acquire) != args.expected) return;
		}
		var col: u32 = args.col_start;
		while (col < args.child.width) : (col += 2) {
			const pt = args.child.pointAt(col, row);
			if (use_f64) {
				const c_re: f64 = @floatCast(pt.re);
				const c_im: f64 = @floatCast(pt.im);
				args.child.set(col, row, computeIterations(c_re, c_im, args.child.max_iter));
			} else {
				args.child.set(col, row, computeIterationsF128(pt.re, pt.im, args.child.max_iter));
			}
		}
	}
}
```

- [ ] **Step 8: Run tests — should pass**

```
nix develop -c zig build test -Doptimize=Debug
```

All tests including the new dispatch tests should pass.

- [ ] **Step 9: Run bench — expect the big jump**

```
./bm
```

Expected: speedup numbers and absolute times should both improve dramatically. Sequential times drop 5-20x. Parallel times drop similarly. Total speedup over the original baseline should be 30-80x.

- [ ] **Step 10: Manual smoke test**

```
./build
./zig-out/bin/mandelbrot --single-frame 2>/dev/null | head -5
```

Should produce valid ANSI fractal output. No NaN or garbage.

- [ ] **Step 11: Commit**

```bash
git add src/core/mandelbrot.zig tests/unit/test_parallel.zig benchmarks/results.log
git commit -m "perf: f64 hot loop with f128 fallback above zoom 10^13"
```

---

### Task 5: `--bench-zoom-sequence` CLI Flag

**Files:**
- Modify: `src/main.zig`
- Modify: `tests/cli/test_cli.bash`

- [ ] **Step 1: Write failing CLI tests**

Append to `tests/cli/test_cli.bash` (before the final line that prints test results):

```bash
# Test: --bench-zoom-sequence produces summary output
output=$("$BINARY" --bench-zoom-sequence 3 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Total:" && echo "$output" | grep -q "Avg/frame:"; then
    pass "--bench-zoom-sequence 3 produces Total and Avg/frame"
else
    fail "--bench-zoom-sequence 3 produces Total and Avg/frame" "rc=$rc"
fi

# Test: --bench-zoom-sequence + --bench-quiet suppresses per-frame output
output=$("$BINARY" --bench-zoom-sequence 3 --bench-quiet 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Total:" && ! echo "$output" | grep -q "Frame 1"; then
    pass "--bench-quiet suppresses per-frame output"
else
    fail "--bench-quiet suppresses per-frame output" "rc=$rc"
fi
```

- [ ] **Step 2: Run CLI tests — should fail**

```
./test
```

Expected: the two new CLI tests fail.

- [ ] **Step 3: Add --bench-zoom-sequence handling to src/main.zig**

In `src/main.zig`, in the argument loop, add after the `--single-frame` handling:

```zig
var bench_zoom_n: ?u32 = null;
var bench_quiet = false;
// ...existing arg loop...
```

And add new arg handlers. Insert after the `--single-frame` branch:

```zig
if (std.mem.eql(u8, arg, "--bench-zoom-sequence")) {
    // Next arg should be N
    if (i + 1 >= args.len) {
        try stderr.writeAll("--bench-zoom-sequence requires N argument\n");
        try stderr.flush();
        return error.BadCliArg;
    }
    bench_zoom_n = std.fmt.parseInt(u32, args[i + 1], 10) catch {
        try stderr.writeAll("--bench-zoom-sequence N must be a positive integer\n");
        try stderr.flush();
        return error.BadCliArg;
    };
    // Skip next arg (the N value)
    continue; // Note: the for-loop needs restructuring to an index-based loop for this
}
if (std.mem.eql(u8, arg, "--bench-quiet")) {
    bench_quiet = true;
}
```

Actually this requires restructuring the arg loop to be index-based since `continue` on a for-each loop doesn't work the same way. Rewrite the arg loop as:

```zig
var i: usize = 1;
while (i < args.len) : (i += 1) {
    const arg = args[i];
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
        // ...existing help printing...
        return;
    }
    if (std.mem.eql(u8, arg, "--about")) {
        // ...existing about printing...
        return;
    }
    if (std.mem.eql(u8, arg, "--single-frame")) {
        single_frame = true;
        continue;
    }
    if (std.mem.eql(u8, arg, "--bench-zoom-sequence")) {
        if (i + 1 >= args.len) {
            try stderr.writeAll("--bench-zoom-sequence requires N argument\n");
            try stderr.flush();
            return error.BadCliArg;
        }
        bench_zoom_n = std.fmt.parseInt(u32, args[i + 1], 10) catch {
            try stderr.writeAll("--bench-zoom-sequence N must be a positive integer\n");
            try stderr.flush();
            return error.BadCliArg;
        };
        i += 1; // Skip the N value
        continue;
    }
    if (std.mem.eql(u8, arg, "--bench-quiet")) {
        bench_quiet = true;
        continue;
    }
}
```

Declare error set at file scope or use anonymous error set return.

Then after the env var parsing and BEFORE `single_frame` handling, add:

```zig
if (bench_zoom_n) |n| {
    try runBenchZoomSequence(allocator, state, n, bench_quiet);
    return;
}
```

And at file scope, add the benchmark function:

```zig
fn runBenchZoomSequence(
    allocator: std.mem.Allocator,
    initial_state: app.AppState,
    n: u32,
    quiet: bool,
) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    // Override: seahorse valley, 120x40 unless env vars already set things
    var state = initial_state;
    // If the user didn't set env vars, use the canonical bench target
    if (std.posix.getenv("MANDELBROT_CENTER_RE") == null) state.center_re = -0.7435;
    if (std.posix.getenv("MANDELBROT_CENTER_IM") == null) state.center_im = 0.1314;
    if (std.posix.getenv("MANDELBROT_ZOOM") == null) state.zoom = 1.0;
    if (std.posix.getenv("MANDELBROT_COLS") == null) state.term_width = 120;
    if (std.posix.getenv("MANDELBROT_ROWS") == null) state.term_height = 40;

    try stderr.print("=== Zoom Sequence Benchmark ({d}x{d}, base_iter={d}, N={d}) ===\n", .{
        state.term_width, state.term_height, state.base_iter, n,
    });
    try stderr.flush();

    var total_compute_ns: u64 = 0;
    var total_render_ns: u64 = 0;
    var timer = try std.time.Timer.start();

    var frame: u32 = 0;
    while (frame < n) : (frame += 1) {
        const render_height: u16 = if (state.show_info and state.term_height > 1)
            state.term_height - 1
        else
            state.term_height;
        const pixel_count = @as(usize, state.term_width) * @as(usize, render_height);

        const iter_buf = try allocator.alloc(f64, pixel_count);
        defer allocator.free(iter_buf);

        timer.reset();
        try @import("mandelbrot").parallelComputeRegion(.{
            .center_re = state.center_re,
            .center_im = state.center_im,
            .zoom = state.zoom,
            .width = state.term_width,
            .height = render_height,
            .max_iter = state.max_iter,
            .aspect_ratio = 0.5,
        }, iter_buf, null);
        const compute_ns = timer.read();
        total_compute_ns += compute_ns;

        timer.reset();
        const frame_bytes = try renderer.renderFrameFromBuffer(.{
            .center_re = state.center_re,
            .center_im = state.center_im,
            .zoom = state.zoom,
            .max_iter = state.max_iter,
            .show_info = state.show_info,
        }, state.term_width, state.term_height, iter_buf, allocator);
        defer allocator.free(frame_bytes);
        const render_ns = timer.read();
        total_render_ns += render_ns;

        if (!quiet) {
            const compute_ms = @as(f64, @floatFromInt(compute_ns)) / 1_000_000.0;
            const render_ms = @as(f64, @floatFromInt(render_ns)) / 1_000_000.0;
            const total_ms = compute_ms + render_ms;
            const zoom_f64: f64 = @floatCast(state.zoom);
            try stderr.print("  Frame {d} (zoom={d:.1e}): compute={d:.2}ms  render={d:.2}ms  total={d:.2}ms\n", .{
                frame + 1, zoom_f64, compute_ms, render_ms, total_ms,
            });
        }

        // Zoom in 2x at center for next frame
        state.zoom *= 2.0;
        state.max_iter = @import("viewport").adaptiveMaxIter(state.zoom, state.base_iter);
    }

    const total_ns = total_compute_ns + total_render_ns;
    const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
    const avg_ms = total_ms / @as(f64, @floatFromInt(n));
    try stderr.print("  Total: {d:.2}ms  Avg/frame: {d:.2}ms  (compute: {d:.2}ms, render: {d:.2}ms)\n", .{
        total_ms,
        avg_ms,
        @as(f64, @floatFromInt(total_compute_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(total_render_ns)) / 1_000_000.0,
    });
    try stderr.flush();
}
```

Also add imports at top of main.zig:
```zig
const mandelbrot_mod = @import("mandelbrot");
```

Wait — actually `mandelbrot` isn't currently imported to `main_mod` in build.zig. Check the exe's imports. If not present, add `mandelbrot` and `viewport` to the exe's root_module imports. Viewport is already there; mandelbrot may need to be added.

In `build.zig`, find the `exe` definition's imports and ensure both `mandelbrot` and `viewport` are present. Current:
```zig
.imports = &.{
    .{ .name = "app", .module = app_mod },
    .{ .name = "terminal", .module = terminal_mod },
    .{ .name = "viewport", .module = viewport_mod },
    .{ .name = "renderer", .module = renderer_mod },
},
```

Add mandelbrot:
```zig
.imports = &.{
    .{ .name = "app", .module = app_mod },
    .{ .name = "terminal", .module = terminal_mod },
    .{ .name = "viewport", .module = viewport_mod },
    .{ .name = "renderer", .module = renderer_mod },
    .{ .name = "mandelbrot", .module = mandelbrot_mod },
},
```

Same for `unit_tests` target if it shares the exe's module config.

- [ ] **Step 4: Update help text in main.zig to document new flags**

In the `--help` output, add lines after `--single-frame`:

```
\\  --bench-zoom-sequence N    Render N zoom-in frames for perf testing, print timing, exit
\\  --bench-quiet              With --bench-zoom-sequence: suppress per-frame output
```

- [ ] **Step 5: Run tests — should pass**

```
./test
```

- [ ] **Step 6: Manual verification**

```
./build
./zig-out/bin/mandelbrot --bench-zoom-sequence 3
```

Expected: 3 frames reported with compute/render/total timings, then Total/Avg summary.

```
./zig-out/bin/mandelbrot --bench-zoom-sequence 3 --bench-quiet
```

Expected: only the summary line, no per-frame detail.

- [ ] **Step 7: End-to-end test with hyperfine**

```
nix develop -c hyperfine --warmup 2 --runs 10 "./zig-out/bin/mandelbrot --bench-zoom-sequence 5 --bench-quiet 2>/dev/null"
```

This should give us an externally-measured baseline for future regression tracking. Don't commit the results yet — we'll manually record the best time.

- [ ] **Step 8: Commit**

```bash
git add src/main.zig tests/cli/test_cli.bash build.zig
git commit -m "feat: --bench-zoom-sequence N and --bench-quiet CLI flags"
```

---

### Task 6: Documentation & Final Bench Run

**Files:**
- Modify: `PLAN.md`
- Modify: `CODE_MINIMAP.md`

- [ ] **Step 1: Update PLAN.md**

Move the completed perf optimization items from "Future Enhancements" to "Completed":

```markdown
## Completed
...existing completed items...
- [x] Parallel speedup improvement (auto-thread-count + interleaved rows) — ~2026-04-19 EST
- [x] f64 hot loop (f128 fallback above zoom 10^13) — ~2026-04-19 EST
- [x] --bench-zoom-sequence CLI flag + hyperfine-friendly --bench-quiet — ~2026-04-19 EST
- [x] Microbenchmark suite (shallow/deep/small) + bm regression detection — ~2026-04-19 EST
```

And remove the corresponding items from "Future Enhancements":
- "Improve parallel speedup" (done)
- "Benchmark regression detection" (done)

Add new future items based on the optimization work:
```markdown
- [ ] Cardioid/bulb early-exit (20-40% fewer iterations in default view)
- [ ] SIMD vectorization (4 pixels at a time via f64x4 vector)
- [ ] Persistent thread pool (skip spawn overhead per-frame)
- [ ] **Double-double (DD) replacement for f128 soft-float path** — on Apple Silicon (and most ARM64 / x86_64), hardware f128 doesn't exist and f128 ops go through slow soft-float (30-100x slower than f64). Double-double represents a high-precision number as two f64 values (hi + lo) using Dekker/Knuth techniques. Gives ~106 bits of mantissa (~30 digits, deep enough for ~10^30 zoom) using hardware f64 throughout. Expected 3-10x speedup over f128 fallback. Add `DD = struct { hi: f64, lo: f64 }` type with Dekker sum/product, plug into `computeIterationsT(DD, ...)` (the generic already exists). Keep f128 version as test ground-truth.
```

- [ ] **Step 2: Update CODE_MINIMAP.md**

In the `src/core/mandelbrot.zig` section, replace existing function list with:

```markdown
## `src/core/mandelbrot.zig`
- `computeIterationsT(comptime T, c_re: T, c_im: T, max_iter)` — generic smooth iteration count (T is f64 or f128)
- `computeIterations(c_re: f64, c_im: f64, max_iter)` — default fast path (f64)
- `computeIterationsF128(c_re: f128, c_im: f128, max_iter)` — precision path for deep zoom (f128)
- `computeRegion(params, out)` — sequential fill (delegates to computeRowStride with num_threads=1)
- `computeRowStride(params, out, thread_idx, num_threads)` — stride-based row assignment (load balanced)
- `parallelComputeRegion(params, out, ?num_threads)` — spawns N threads; null = auto-detect (cap 12)
- `autoThreadCount()` — returns `min(max(getCpuCount(), 1), 12)`
- `computeRegionDirect(level)` — fill a CacheLevel (dispatches to f64/f128 based on step size)
- `computeDoubling(parent, child, ?generation)` — 3-offset doubling (with dispatch)
- `resetDispatchCounters() / f64DispatchCount() / f128DispatchCount()` — test-only dispatch observability
- `F128_DISPATCH_THRESHOLD` — zoom threshold (1.0e13) for f128 fallback
- `F128_STEP_THRESHOLD` — step-size threshold (2.0e-15) for cache-level f128 fallback
- `RegionParams`, `INTERIOR`, `MAX_THREADS` — constants/types
```

In the `src/main.zig` section, add the new bench function:

```markdown
- `runBenchZoomSequence(allocator, state, n, quiet)` — `--bench-zoom-sequence` impl: N zoom-in frames with timing
```

- [ ] **Step 3: Final test and bench run**

```
./test
./bm
```

All tests pass. Bench shows final performance numbers.

- [ ] **Step 4: Record perf evidence**

Look at `benchmarks/results.log`. Verify the performance trajectory:
- Baseline (before task 1): 1.55x speedup, ~41ms sequential / ~27ms parallel
- After task 2 (thread count): ~3x speedup
- After task 3 (interleaved rows): ~6-8x speedup
- After task 4 (f64 hot loop): 30-80x faster absolute times

If any step didn't meet its target, the bench log will show where. Add a note to PLAN.md under a "Performance Evidence" section pointing to `benchmarks/results.log` with the commit SHAs that made each jump.

- [ ] **Step 5: Commit docs**

```bash
git add PLAN.md CODE_MINIMAP.md
git commit -m "docs: update PLAN.md and CODE_MINIMAP.md for perf optimization"
```

---

## Self-Review

**Spec coverage:**
- ✅ Thread count auto-detect (Task 2)
- ✅ Interleaved row assignment (Task 3)
- ✅ f64 hot loop with f128 fallback (Task 4)
- ✅ Dispatch counters for test verification (Task 4, Step 4)
- ✅ F128_DISPATCH_THRESHOLD = 1.0e13 (Task 4)
- ✅ F128_STEP_THRESHOLD for cache-level dispatch (Task 4, Step 7)
- ✅ `--bench-zoom-sequence N` CLI flag (Task 5)
- ✅ `--bench-quiet` flag (Task 5)
- ✅ Expanded microbenchmark scenarios: shallow/deep/small (Task 1)
- ✅ `bm` regression detection (Task 1)
- ✅ f64/f128 equivalence at shallow zoom test (Task 4, Step 1)
- ✅ Thread count variation correctness test (Task 2, Step 1)

**Placeholder scan:** No TBDs or TODOs. All code blocks complete.

**Type consistency:**
- `computeRowStride(params, out, thread_idx, num_threads)` signature consistent between Task 3 and Task 4
- `parallelComputeRegion(params, out, ?num_threads)` signature consistent between Task 2, Task 4, and app.zig
- `BAILOUT_SQ_F64` named consistently (renamed from BAILOUT_SQ in Task 4)
- `F128_DISPATCH_THRESHOLD` and `F128_STEP_THRESHOLD` distinct constants with clear purposes
- Dispatch counters (`g_f64_dispatch`, `g_f128_dispatch`) consistent naming

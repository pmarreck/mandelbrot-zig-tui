// src/tui/pool.zig
// Background pre-computation scheduler.
// Manages a coordinator thread that progressively fills cache levels 1-4
// using the 3-offset doubling pattern. Cancellable via atomic generation counter.

const std = @import("std");
const cache_mod = @import("cache");
const mandelbrot = @import("mandelbrot");
const runtime = @import("runtime");

/// Sleep for `ms` milliseconds via `std.Io.sleep`. Errors are swallowed since
/// the coordinator already polls a stop flag; a cancelled sleep just falls
/// through to the next loop iteration.
fn sleepMs(ms: u64) void {
	std.Io.sleep(runtime.io(), .fromMilliseconds(@intCast(ms)), .awake) catch {};
}

pub const BackgroundScheduler = struct {
	/// Atomic generation counter. Bumped on every user action that changes
	/// the viewport. Workers check this per-row and bail if it changes.
	generation: std.atomic.Value(u32),
	/// Long-lived coordinator thread. Drives computeDoubling for each level,
	/// which spawns N worker threads (auto-detected) per doubling step.
	coordinator: ?std.Thread,
	allocator: std.mem.Allocator,
	/// Shared pointer to the cache stack — owned by app.zig.
	cache: *cache_mod.CacheStack,
	/// Atomic flag to signal coordinator to exit.
	running: std.atomic.Value(bool),

	pub fn init(allocator: std.mem.Allocator, cache_stack: *cache_mod.CacheStack) BackgroundScheduler {
		return .{
			.generation = std.atomic.Value(u32).init(0),
			.coordinator = null,
			.allocator = allocator,
			.cache = cache_stack,
			.running = std.atomic.Value(bool).init(false),
		};
	}

	/// Start background pre-computation if not already running.
	/// If already running, bumps generation to cancel stale work and restart on new state.
	pub fn requestWork(self: *BackgroundScheduler) void {
		_ = self.generation.fetchAdd(1, .acq_rel);

		if (self.coordinator != null) {
			// Coordinator is already running — it will see the new generation.
			return;
		}

		self.running.store(true, .release);
		self.coordinator = std.Thread.spawn(.{}, coordinatorLoop, .{self}) catch null;
	}

	/// Signal coordinator to stop and wait for it to exit.
	/// Safe to call multiple times.
	pub fn stop(self: *BackgroundScheduler) void {
		self.running.store(false, .release);
		_ = self.generation.fetchAdd(1, .acq_rel);
		if (self.coordinator) |coord| {
			coord.join();
			self.coordinator = null;
		}
	}

	/// Bump the generation counter to cancel current background work.
	/// Does not stop the coordinator — it will pick up new work on next iteration.
	pub fn cancel(self: *BackgroundScheduler) void {
		_ = self.generation.fetchAdd(1, .acq_rel);
	}

	/// Main loop of the coordinator thread.
	/// Finds the next incomplete level and computes it via doubling.
	/// Sleeps when all levels are complete.
	fn coordinatorLoop(self: *BackgroundScheduler) void {
		while (self.running.load(.acquire)) {
			const gen = self.generation.load(.acquire);

			const next = self.cache.nextIncompleteLevel() orelse {
				// All levels complete — sleep briefly and check again
				sleepMs(50);
				continue;
			};

			// Level 0 is foreground's job
			if (next == 0) {
				sleepMs(10);
				continue;
			}

			// Ensure parent level exists and is complete
			const parent_idx = next - 1;
			if (self.cache.levels[parent_idx]) |parent| {
				if (!parent.complete) {
					sleepMs(10);
					continue;
				}
			} else {
				sleepMs(10);
				continue;
			}

			// Check generation hasn't changed before expensive work
			if (self.generation.load(.acquire) != gen) continue;

			// Create the level if it doesn't exist
			if (self.cache.levels[next] == null) {
				self.cache.createLevel(self.allocator, next) catch {
					sleepMs(100);
					continue;
				};
			}

			// Inherit parent data, then compute doubling
			if (self.cache.levels[next]) |*child| {
				if (self.cache.levels[parent_idx]) |parent| {
					child.inheritFromParent(parent);
				}
			}

			// Check generation again before the expensive step
			if (self.generation.load(.acquire) != gen) continue;

			if (self.cache.levels[next]) |*child| {
				if (self.cache.levels[parent_idx]) |*parent| {
					mandelbrot.computeDoubling(parent, child, &self.generation) catch {
						// Spawn failure — back off briefly and retry
						sleepMs(100);
						continue;
					};
				}
			}
		}
	}
};

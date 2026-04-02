const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // ── Shared module definitions ───────────────────────────────────
    // These are reused by both the main executable and test targets.

    const mandelbrot_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mandelbrot.zig"),
    });
    const coloring_mod = b.createModule(.{
        .root_source_file = b.path("src/core/coloring.zig"),
        .imports = &.{
            .{ .name = "mandelbrot", .module = mandelbrot_mod },
        },
    });
    const viewport_mod = b.createModule(.{
        .root_source_file = b.path("src/core/viewport.zig"),
    });
    const input_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/input.zig"),
    });
    const terminal_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/terminal.zig"),
    });
    const renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/renderer.zig"),
        .imports = &.{
            .{ .name = "mandelbrot", .module = mandelbrot_mod },
            .{ .name = "coloring", .module = coloring_mod },
        },
    });
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/app.zig"),
        .imports = &.{
            .{ .name = "terminal", .module = terminal_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "renderer", .module = renderer_mod },
            .{ .name = "viewport", .module = viewport_mod },
        },
    });

    // ── Main executable ─────────────────────────────────────────────

    const exe = b.addExecutable(.{
        .name = "mandelbrot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "app", .module = app_mod },
                .{ .name = "terminal", .module = terminal_mod },
                .{ .name = "viewport", .module = viewport_mod },
                .{ .name = "renderer", .module = renderer_mod },
            },
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

    // ── Tests ───────────────────────────────────────────────────────

    const test_step = b.step("test", "Run unit tests");

    // main.zig tests (needs same imports as the exe)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "app", .module = app_mod },
                .{ .name = "terminal", .module = terminal_mod },
                .{ .name = "viewport", .module = viewport_mod },
                .{ .name = "renderer", .module = renderer_mod },
            },
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // core/mandelbrot tests
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_mandelbrot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mandelbrot", .module = mandelbrot_mod },
            },
        }),
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    test_step.dependOn(&run_core_tests.step);

    // core/viewport tests
    const viewport_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_viewport.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "viewport", .module = viewport_mod },
            },
        }),
    });
    const run_viewport_tests = b.addRunArtifact(viewport_tests);
    test_step.dependOn(&run_viewport_tests.step);

    // core/coloring tests
    const coloring_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_coloring.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "coloring", .module = coloring_mod },
                .{ .name = "mandelbrot", .module = mandelbrot_mod },
            },
        }),
    });
    const run_coloring_tests = b.addRunArtifact(coloring_tests);
    test_step.dependOn(&run_coloring_tests.step);

    // tui/input tests
    const input_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_input.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "input", .module = input_mod },
            },
        }),
    });
    const run_input_tests = b.addRunArtifact(input_tests);
    test_step.dependOn(&run_input_tests.step);

    // tui/renderer tests
    const renderer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_renderer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "renderer", .module = renderer_mod },
            },
        }),
    });
    const run_renderer_tests = b.addRunArtifact(renderer_tests);
    test_step.dependOn(&run_renderer_tests.step);

    // tui/app tests (runs the inline tests in app.zig)
    const app_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui/app.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "terminal", .module = terminal_mod },
                .{ .name = "input", .module = input_mod },
                .{ .name = "renderer", .module = renderer_mod },
                .{ .name = "viewport", .module = viewport_mod },
            },
        }),
    });
    const run_app_tests = b.addRunArtifact(app_tests);
    test_step.dependOn(&run_app_tests.step);
}

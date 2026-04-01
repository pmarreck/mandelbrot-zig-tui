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

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_mandelbrot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "mandelbrot",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/core/mandelbrot.zig"),
                    }),
                },
            },
        }),
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    test_step.dependOn(&run_core_tests.step);

    const viewport_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_viewport.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "viewport",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/core/viewport.zig"),
                    }),
                },
            },
        }),
    });
    const run_viewport_tests = b.addRunArtifact(viewport_tests);
    test_step.dependOn(&run_viewport_tests.step);

    const coloring_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_coloring.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "coloring",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/core/coloring.zig"),
                    }),
                },
            },
        }),
    });
    const run_coloring_tests = b.addRunArtifact(coloring_tests);
    test_step.dependOn(&run_coloring_tests.step);

    const input_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/test_input.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "input",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/tui/input.zig"),
                    }),
                },
            },
        }),
    });
    const run_input_tests = b.addRunArtifact(input_tests);
    test_step.dependOn(&run_input_tests.step);

    const mandelbrot_mod = b.createModule(.{
        .root_source_file = b.path("src/core/mandelbrot.zig"),
    });
    const coloring_mod = b.createModule(.{
        .root_source_file = b.path("src/core/coloring.zig"),
    });
    const renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/tui/renderer.zig"),
        .imports = &.{
            .{ .name = "mandelbrot", .module = mandelbrot_mod },
            .{ .name = "coloring", .module = coloring_mod },
        },
    });
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
}

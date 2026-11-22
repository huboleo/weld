const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const description = b.createModule(.{
        .root_source_file = b.path("shared/description.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "weld",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const runtime = b.addLibrary(.{
        .name = "weld_runtime",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/runtime.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    runtime.root_module.addImport("description", description);

    b.installArtifact(runtime);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

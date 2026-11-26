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

    exe.root_module.addImport("description", description);

    // build.h as Zig declarations, so the runtime's tests can compare the
    // runtime's hand-written mirrors against the real C structs.
    const build_h = b.addTranslateC(.{
        .root_source_file = b.path("include/weld/build.h"),
        .target = target,
        .optimize = optimize,
    });
    runtime.root_module.addImport("build_h", build_h.createModule());

    b.installArtifact(runtime);

    // weld never calls the runtime itself: it writes these two files to disk and
    // links each project's build script against them into the build runner.
    exe.root_module.addAnonymousImport("libweld_runtime.a", .{ .root_source_file = runtime.getEmittedBin() });
    exe.root_module.addAnonymousImport("weld/build.h", .{ .root_source_file = b.path("include/weld/build.h") });
    exe.root_module.addAnonymousImport("weld/build.hpp", .{ .root_source_file = b.path("include/weld/build.hpp") });
    exe.root_module.addAnonymousImport("bridge.cpp", .{ .root_source_file = b.path("runtime/bridge.cpp") });

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const runtime_tests = b.addTest(.{
        .root_module = runtime.root_module,
    });

    const run_runtime_tests = b.addRunArtifact(runtime_tests);

    // A module of its own: `description` has no target, it takes the one of whoever imports it.
    const description_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("shared/description.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_description_tests = b.addRunArtifact(description_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_description_tests.step);
}

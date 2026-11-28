const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    b.dependOnFileContents(b.path("src/zig-release.json"));
    const release_path = b.root.join(b.allocator, "src/zig-release.json") catch @panic("OOM");
    const release_bytes = release_path.root_dir.handle.readFileAlloc(
        b.graph.io,
        release_path.sub_path,
        b.allocator,
        .limited(64 * 1024),
    ) catch |err| std.process.fatal("can't read src/zig-release.json: {t}", .{err});

    const release = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, release_bytes, .{}) catch |err|
        std.process.fatal("src/zig-release.json is not valid JSON: {t}", .{err});

    const zig_version = release.object.get("version").?.string;
    const host_key = b.fmt("{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) });
    const entry = release.object.get(host_key) orelse
        std.process.fatal("Zig {s} has no release for {s}", .{ zig_version, host_key });
    const zig_tarball = entry.object.get("tarball").?.string;
    const zig_shasum = entry.object.get("shasum").?.string;

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

    const zig_release = b.addOptions();
    zig_release.addOption([]const u8, "version", zig_version);
    zig_release.addOption([]const u8, "tarball", zig_tarball);
    zig_release.addOption([]const u8, "shasum", zig_shasum);

    exe.root_module.addOptions("zig_release", zig_release);

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

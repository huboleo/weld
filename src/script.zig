const std = @import("std");
const context = @import("context.zig");
const builtin = @import("builtin");
const description = @import("description");
const Context = context.Context;
const Language = context.Language;
const Description = description.Description;

const runtime_lib = @embedFile("libweld_runtime.a");
const build_h = @embedFile("weld/build.h");
const build_hpp = @embedFile("weld/build.hpp");
const bridge = @embedFile("bridge.cpp");

// Where the runtime is written, inside the project.
const runtime_include_dir = "weld-out/runtime/include"; // passed to -I
const runtime_header_dir = runtime_include_dir ++ "/weld"; // so <weld/build.h> resolves
const runtime_c_header_path = runtime_header_dir ++ "/build.h";
const runtime_cpp_header_path = runtime_header_dir ++ "/build.hpp";
const runtime_bridge_path = "weld-out/runtime/bridge.cpp";
const runtime_lib_dir = "weld-out/runtime/lib";
const runtime_lib_path = runtime_lib_dir ++ "/libweld_runtime.a";
const runner_path = "weld-out/build-runner" ++ builtin.target.exeFileExt();
const description_path = "weld-out/description.json";

/// Runs the project's build script and returns what it declared.
pub fn describe(ctx: Context) !Description {
    const language = try findScript(ctx);
    try writeRuntime(ctx);
    try compileRunner(ctx, language);
    try runRunner(ctx);
    return readDescription(ctx);
}

/// Writes the embedded runtime and its header into the project, where the
/// compiler can read them.
fn writeRuntime(ctx: Context) !void {
    try ctx.cwd.createDirPath(ctx.io, runtime_header_dir);
    try ctx.cwd.writeFile(ctx.io, .{ .sub_path = runtime_c_header_path, .data = build_h });
    try ctx.cwd.writeFile(ctx.io, .{ .sub_path = runtime_cpp_header_path, .data = build_hpp });

    try ctx.cwd.createDirPath(ctx.io, runtime_lib_dir);
    try ctx.cwd.writeFile(ctx.io, .{ .sub_path = runtime_lib_path, .data = runtime_lib });
    try ctx.cwd.writeFile(ctx.io, .{ .sub_path = runtime_bridge_path, .data = bridge });
}

/// Compiles the project's build script and links it with the runtime (written by writeRuntime) into the build runner.
/// Compiler errors are shown to the user unchanged.
fn compileRunner(ctx: Context, language: Language) !void {
    const argv: []const []const u8 = switch (language) {
        .c => &.{ "zig", "cc", "-I", runtime_include_dir, "build.c", runtime_lib_path, "-o", runner_path },
        .@"c++" => &.{ "zig", "c++", "-std=c++23", "-I", runtime_include_dir, "build.cpp", runtime_bridge_path, runtime_lib_path, "-o", runner_path },
    };

    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = argv,
        .cwd = context.childCwd(ctx),
    });

    if (!result.term.success()) {
        try ctx.err.print("the build script failed to compile:\n", .{});
        try ctx.err.print("{s}", .{result.stderr});
        return error.AlreadyReported;
    }
}

/// Runs the build runner, which writes the description to description_path.
/// The script's own output goes straight to the user's terminal.
fn runRunner(ctx: Context) !void {
    var child = try std.process.spawn(ctx.io, .{
        .argv = &.{ runner_path, "--out", description_path },
        .cwd = context.childCwd(ctx),
    });

    const term = try child.wait(ctx.io);

    switch (term) {
        .exited => |code| if (code != 0) return error.AlreadyReported,
        .signal => |sig| {
            try ctx.err.print("build script crashed ({t})\n", .{sig});
            return error.AlreadyReported;
        },
        else => {
            try ctx.err.print("build script ended unexpectedly\n", .{});
            return error.AlreadyReported;
        },
    }
}

/// Reads back the description the build runner wrote, and checks that it uses the current version.
fn readDescription(ctx: Context) !Description {
    const bytes = try ctx.cwd.readFileAlloc(ctx.io, description_path, ctx.arena, .unlimited);
    const desc = try std.json.parseFromSliceLeaky(Description, ctx.arena, bytes, .{});
    if (desc.version != description.current_version) {
        try ctx.err.print("{s} has version {d}, expected {d}\n", .{ description_path, desc.version, description.current_version });
        return error.AlreadyReported;
    }

    return desc;
}

/// Returns the language of the project's build script, or an error if build scripts exist in both languages or none
fn findScript(ctx: Context) !Language {
    const has_c = try context.fileExists(ctx, "build.c");
    const has_cpp = try context.fileExists(ctx, "build.cpp");

    if (has_c and has_cpp) {
        try ctx.err.print("both build.c and build.cpp exist, a project can only have one\n", .{});
        return error.AlreadyReported;
    }

    if (!has_c and !has_cpp) {
        try ctx.err.print("no build.c or build.cpp found\n", .{});
        return error.AlreadyReported;
    }

    if (has_cpp) {
        return Language.@"c++";
    }

    return Language.c;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const testContext = context.testContext;

test "writeRuntime: writes every file where the compiler expects it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try writeRuntime(ctx);

    const lib = try tmp.dir.readFileAlloc(testing.io, runtime_lib_path, testing.allocator, .unlimited);
    defer testing.allocator.free(lib);
    // Every static library (ar archive) starts with this signature.
    try testing.expect(std.mem.startsWith(u8, lib, "!<arch>\n"));

    const c_header = try tmp.dir.readFileAlloc(testing.io, runtime_c_header_path, testing.allocator, .unlimited);
    defer testing.allocator.free(c_header);
    try testing.expectEqualStrings(build_h, c_header);

    const cpp_header = try tmp.dir.readFileAlloc(testing.io, runtime_cpp_header_path, testing.allocator, .unlimited);
    defer testing.allocator.free(cpp_header);
    try testing.expectEqualStrings(build_hpp, cpp_header);

    const written_bridge = try tmp.dir.readFileAlloc(testing.io, runtime_bridge_path, testing.allocator, .unlimited);
    defer testing.allocator.free(written_bridge);
    try testing.expectEqualStrings(bridge, written_bridge);
}

test "findScript: build.c gives c" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.c", .data = "" });

    try testing.expectEqual(Language.c, try findScript(ctx));
}

test "findScript: build.cpp gives c++" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.cpp", .data = "" });

    try testing.expectEqual(Language.@"c++", try findScript(ctx));
}

test "findScript: both scripts is an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.c", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.cpp", .data = "" });

    try testing.expectError(error.AlreadyReported, findScript(ctx));
    try testing.expectEqualStrings("both build.c and build.cpp exist, a project can only have one\n", output.written());
}

test "findScript: no script is an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try testing.expectError(error.AlreadyReported, findScript(ctx));
    try testing.expectEqualStrings("no build.c or build.cpp found\n", output.written());
}

test "compileRunner: links a build script with the runtime" {
    // std.process.run allocates the child's output from ctx.arena, so the
    // tests give it a real arena instead of the leak-checking allocator.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.c", .data = @embedFile("templates/build_exe.c") });
    try writeRuntime(ctx);

    try compileRunner(ctx, .c);

    try testing.expect(try context.fileExists(ctx, runner_path));
}

test "compileRunner: a script that doesn't compile shows the compiler's errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.c", .data = "void build(weld_build* b) { oops }" });
    try writeRuntime(ctx);

    try testing.expectError(error.AlreadyReported, compileRunner(ctx, .c));
    try testing.expect(std.mem.indexOf(u8, output.written(), "error:") != null);
}

test "compileRunner: compiles build.cpp as C++23" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "build.cpp",
        .data =
        \\#include <weld/build.hpp>
        \\static_assert(__cplusplus >= 202302L);
        \\void build(weld::Build&) {}
        ,
    });
    try writeRuntime(ctx);

    try compileRunner(ctx, .@"c++");

    try testing.expect(try context.fileExists(ctx, runner_path));
}

test "compileRunner: a C++ script that doesn't compile shows the compiler's errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.cpp", .data = "void build(weld::Build& b) { oops }" });
    try writeRuntime(ctx);

    try testing.expectError(error.AlreadyReported, compileRunner(ctx, .@"c++"));
    try testing.expect(std.mem.indexOf(u8, output.written(), "error:") != null);
}

/// Writes `script` as build.c and compiles it into the build runner.
fn prepareRunner(ctx: Context, script: []const u8) !void {
    try ctx.cwd.writeFile(ctx.io, .{ .sub_path = "build.c", .data = script });
    try writeRuntime(ctx);
    try compileRunner(ctx, .c);
}

test "runRunner: a working script writes the description" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try prepareRunner(ctx, @embedFile("templates/build_exe.c"));

    try runRunner(ctx);

    const json = try tmp.dir.readFileAlloc(testing.io, description_path, arena.allocator(), .unlimited);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"executable\"") != null);
}

test "runRunner: a script that fails is reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    // NULL options: the runtime prints why (to the inherited stderr) and exits with 1.
    try prepareRunner(ctx,
        \\#include <weld/build.h>
        \\void build(weld_build* b) { weld_add_executable(b, 0); }
    );

    try testing.expectError(error.AlreadyReported, runRunner(ctx));
}

test "runRunner: a script that crashes is reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    // `volatile` keeps the compiler from optimizing the bad write away.
    try prepareRunner(ctx,
        \\#include <weld/build.h>
        \\void build(weld_build* b) { (void)b; *(volatile int*)0 = 1; }
    );

    try testing.expectError(error.AlreadyReported, runRunner(ctx));
    try testing.expect(std.mem.indexOf(u8, output.written(), "build script crashed") != null);
}

test "readDescription: reads back what the build runner wrote" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try prepareRunner(ctx, @embedFile("templates/build_lib.c"));
    try runRunner(ctx);

    const desc = try readDescription(ctx);

    try testing.expectEqual(1, desc.targets.len);
    const target = desc.targets[0];
    try testing.expectEqual(.library, target.kind);
    try testing.expectEqualStrings("app", target.name);
    try testing.expectEqual(1, target.sources.len);
    try testing.expectEqualStrings("src/", target.sources[0]);
    try testing.expectEqual(1, target.includes.len);
    try testing.expectEqualStrings("include/", target.includes[0]);
}

test "readDescription: a different version is reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try tmp.dir.createDirPath(testing.io, "weld-out");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = description_path, .data = "{\"version\":0,\"targets\":[]}" });

    try testing.expectError(error.AlreadyReported, readDescription(ctx));
    try testing.expectEqualStrings("weld-out/description.json has version 0, expected 1\n", output.written());
}

test "readDescription: a missing version doesn't parse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try tmp.dir.createDirPath(testing.io, "weld-out");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = description_path, .data = "{\"targets\":[]}" });

    try testing.expectError(error.MissingField, readDescription(ctx));
}

test "describe: runs the build script and returns its targets" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.c", .data = @embedFile("templates/build_exe.c") });

    const desc = try describe(ctx);

    try testing.expectEqual(1, desc.targets.len);
    try testing.expectEqual(.executable, desc.targets[0].kind);
    try testing.expectEqualStrings("app", desc.targets[0].name);
}

test "describe: runs a C++ build script and returns its targets" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    // The executable leaves its options out, so it gets the runtime's defaults.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "build.cpp",
        .data =
        \\#include <weld/build.hpp>
        \\void build(weld::Build& b) {
        \\    b.add_executable({});
        \\    b.add_library({
        \\        .name = "shapes",
        \\        .sources = {"lib/", "extra/circle.cpp"},
        \\        .includes = {"include/"},
        \\    });
        \\}
        ,
    });

    const desc = try describe(ctx);

    try testing.expectEqual(2, desc.targets.len);

    const executable = desc.targets[0];
    try testing.expectEqual(.executable, executable.kind);
    try testing.expectEqualStrings("app", executable.name);
    try testing.expectEqual(1, executable.sources.len);
    try testing.expectEqualStrings("src/", executable.sources[0]);
    try testing.expectEqual(0, executable.includes.len);

    const library = desc.targets[1];
    try testing.expectEqual(.library, library.kind);
    try testing.expectEqualStrings("shapes", library.name);
    try testing.expectEqual(2, library.sources.len);
    try testing.expectEqualStrings("lib/", library.sources[0]);
    try testing.expectEqualStrings("extra/circle.cpp", library.sources[1]);
    try testing.expectEqual(1, library.includes.len);
    try testing.expectEqualStrings("include/", library.includes[0]);
}

test "describe: a directory without a build script writes nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();

    try testing.expectError(error.AlreadyReported, describe(ctx));
    try testing.expect(!try context.fileExists(ctx, "weld-out"));
}

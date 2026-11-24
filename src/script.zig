const std = @import("std");
const context = @import("context.zig");
const builtin = @import("builtin");
const Context = context.Context;
const Language = context.Language;

const runtime_lib = @embedFile("libweld_runtime.a");
const build_h = @embedFile("weld/build.h");

// Where the runtime is written, inside the project.
const runtime_include_dir = "weld-out/runtime/include"; // passed to -I
const runtime_header_dir = runtime_include_dir ++ "/weld"; // so <weld/build.h> resolves
const runtime_header_path = runtime_header_dir ++ "/build.h";
const runtime_lib_dir = "weld-out/runtime/lib";
const runtime_lib_path = runtime_lib_dir ++ "/libweld_runtime.a";
const runner_path = "weld-out/build-runner" ++ builtin.target.exeFileExt();
const description_path = "weld-out/description.json";

/// Writes the embedded runtime and its header into the project, where the
/// compiler can read them.
fn writeRuntime(ctx: Context) !void {
    try ctx.cwd.createDirPath(ctx.io, runtime_header_dir);
    try ctx.cwd.writeFile(ctx.io, .{ .sub_path = runtime_header_path, .data = build_h });

    try ctx.cwd.createDirPath(ctx.io, runtime_lib_dir);
    try ctx.cwd.writeFile(ctx.io, .{ .sub_path = runtime_lib_path, .data = runtime_lib });
}

/// Compiles the project's build script and links it with the runtime (written by writeRuntime) into the build runner.
/// Compiler errors are shown to the user unchanged.
fn compileRunner(ctx: Context, language: Language) !void {
    const argv: []const []const u8 = switch (language) {
        .c => &.{ "zig", "cc", "-I", runtime_include_dir, "build.c", runtime_lib_path, "-o", runner_path },
        // Needs build.hpp and weld's bridge.cpp, which don't exist yet. Once they do
        // (with writeRuntime also writing runtime_bridge_path), this becomes:
        // .@"c++" => &.{ "zig", "c++", "-I", runtime_include_dir, "build.cpp", runtime_bridge_path, runtime_lib_path, "-o", runner_path },
        .@"c++" => {
            try ctx.err.print("build.cpp is not supported yet\n", .{});
            return error.AlreadyReported;
        },
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

test "writeRuntime: writes the header and the library where the compiler expects them" {
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

    const header = try tmp.dir.readFileAlloc(testing.io, runtime_header_path, testing.allocator, .unlimited);
    defer testing.allocator.free(header);
    try testing.expectEqualStrings(build_h, header);
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

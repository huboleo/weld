const std = @import("std");
const context = @import("context.zig");
const description = @import("description");
const paths = @import("paths.zig");

const Context = context.Context;
const Description = description.Description;
const Target = description.Target;

const compile_commands_path = "weld-out/compile_commands.json";

const Entry = struct {
    directory: []const u8,
    file: []const u8,
    arguments: []const []const u8,
};

pub fn write(ctx: Context, desc: Description) !void {
    const directory = try ctx.cwd.realPathFileAlloc(ctx.io, ".", ctx.arena);
    var entries: std.ArrayList(Entry) = .empty;

    for (desc.targets) |target| {
        const files = try paths.expand(ctx, target.sources);

        for (files) |file| {
            const arguments = try prepareArguments(ctx, target, file);
            const entry: Entry = .{
                .directory = directory,
                .file = file,
                .arguments = arguments,
            };

            try entries.append(ctx.arena, entry);
        }
    }

    const json = try std.json.Stringify.valueAlloc(ctx.arena, entries.items, .{ .whitespace = .indent_2 });
    try ctx.cwd.writeFile(ctx.io, .{
        .sub_path = compile_commands_path,
        .data = json,
    });
}

fn prepareArguments(ctx: Context, target: Target, file: []const u8) ![]const []const u8 {
    var arguments: std.ArrayList([]const u8) = .empty;

    if (std.mem.eql(u8, std.fs.path.extension(file), ".c")) {
        try arguments.append(ctx.arena, "clang");
        try arguments.append(ctx.arena, standardFlag(target.c_standard));
    } else {
        try arguments.append(ctx.arena, "clang++");
        try arguments.append(ctx.arena, standardFlag(target.cpp_standard));
    }

    try arguments.append(ctx.arena, "-c");
    try arguments.append(ctx.arena, file);

    for (target.includes) |include| {
        try arguments.append(ctx.arena, "-I");
        try arguments.append(ctx.arena, include);
    }

    return arguments.items;
}

/// Returns the compiler's flag for a C or C++ standard, e.g. "-std=c++20". `inline else` makes one
/// case per standard, so every flag is put together at compile time.
fn standardFlag(standard: anytype) []const u8 {
    return switch (standard) {
        inline else => |s| "-std=" ++ @tagName(s),
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const testContext = context.testContext;

fn testTarget(sources: []const []const u8, includes: []const []const u8) Target {
    return .{
        .kind = .executable,
        .name = "app",
        .sources = sources,
        .includes = includes,
        .c_standard = .gnu17,
        .cpp_standard = .@"c++23",
    };
}

/// Checks the arguments `prepareArguments` gives for `file` in `target`.
fn expectArguments(expected: []const []const u8, target: Target, file: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();

    try testing.expectEqualDeep(expected, try prepareArguments(ctx, target, file));
}

test "prepareArguments: C files use clang, C++ files clang++" {
    const target = testTarget(&.{}, &.{});

    try expectArguments(&.{ "clang", "-std=gnu17", "-c", "main.c" }, target, "main.c");
    try expectArguments(&.{ "clang++", "-std=c++23", "-c", "main.cc" }, target, "main.cc");
    try expectArguments(&.{ "clang++", "-std=c++23", "-c", "main.cpp" }, target, "main.cpp");
    try expectArguments(&.{ "clang++", "-std=c++23", "-c", "main.cxx" }, target, "main.cxx");
    try expectArguments(&.{ "clang++", "-std=c++23", "-c", "main.c++" }, target, "main.c++");
}

test "prepareArguments: the standards come from the target" {
    var target = testTarget(&.{}, &.{});
    target.c_standard = .c11;
    target.cpp_standard = .@"c++20";

    try expectArguments(&.{ "clang", "-std=c11", "-c", "main.c" }, target, "main.c");
    try expectArguments(&.{ "clang++", "-std=c++20", "-c", "main.cpp" }, target, "main.cpp");
}

test "prepareArguments: every include gets its own -I, in order" {
    try expectArguments(
        &.{ "clang", "-std=gnu17", "-c", "main.c", "-I", "include/" },
        testTarget(&.{}, &.{"include/"}),
        "main.c",
    );
    try expectArguments(
        &.{ "clang", "-std=gnu17", "-c", "main.c", "-I", "include/", "-I", "deps/json/" },
        testTarget(&.{}, &.{ "include/", "deps/json/" }),
        "main.c",
    );
}

test "write: one entry for every file of every target" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    for ([_][]const u8{ "weld-out", "src", "net" }) |dir| try tmp.dir.createDirPath(testing.io, dir);
    for ([_][]const u8{ "src/main.cpp", "src/util.c", "net/http.c" }) |file| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = file, .data = "" });
    }

    try write(ctx, .{
        .version = description.current_version,
        .targets = &.{
            testTarget(&.{"src/"}, &.{"include/"}),
            testTarget(&.{"net/"}, &.{}),
        },
    });

    // The path is spelled out because clangd only finds a file with exactly this name.
    const json = try tmp.dir.readFileAlloc(testing.io, "weld-out/compile_commands.json", ctx.arena, .unlimited);
    const entries = try std.json.parseFromSliceLeaky([]const Entry, ctx.arena, json, .{});

    const root: []const u8 = try tmp.dir.realPathFileAlloc(testing.io, ".", ctx.arena);
    try testing.expect(std.fs.path.isAbsolute(root));

    // File paths are in the system's own form: src/main.cpp, or src\main.cpp on Windows.
    const main_cpp = "src" ++ std.fs.path.sep_str ++ "main.cpp";
    const util_c = "src" ++ std.fs.path.sep_str ++ "util.c";
    const http_c = "net" ++ std.fs.path.sep_str ++ "http.c";

    try testing.expectEqualDeep(@as([]const Entry, &.{
        .{ .directory = root, .file = main_cpp, .arguments = &.{ "clang++", "-std=c++23", "-c", main_cpp, "-I", "include/" } },
        .{ .directory = root, .file = util_c, .arguments = &.{ "clang", "-std=gnu17", "-c", util_c, "-I", "include/" } },
        .{ .directory = root, .file = http_c, .arguments = &.{ "clang", "-std=gnu17", "-c", http_c } },
    }), entries);
}

test "write: a missing source is reported and no file is written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try tmp.dir.createDirPath(testing.io, "weld-out");

    try testing.expectError(error.AlreadyReported, write(ctx, .{
        .version = description.current_version,
        .targets = &.{testTarget(&.{"src/"}, &.{})},
    }));

    try testing.expectEqualStrings("source 'src/' not found\n", output.written());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, compile_commands_path, .{}));
}

const std = @import("std");
const context = @import("context.zig");
const Context = context.Context;

/// What a target's `sources` stand for, relative to the project root.
pub const Sources = struct {
    /// Sorted and without duplicates.
    files: []const []const u8,
    /// The entries that are directories, passed to the compiler as `-iquote`. They keep the
    /// order of `sources`, because the first directory with a header wins.
    directories: []const []const u8,
};

/// Finds the source files that `paths` stand for: a file stands for itself, a directory for
/// every source under it, recursively.
pub fn expand(ctx: Context, paths: []const []const u8) !Sources {
    var files: std.ArrayList([]const u8) = .empty;
    var directories: std.ArrayList([]const u8) = .empty;

    for (paths) |path| {
        const stat = ctx.cwd.statFile(ctx.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try ctx.err.print("source '{s}' not found\n", .{path});
                return error.AlreadyReported;
            },
            else => return err,
        };

        if (stat.kind == .directory) {
            const directory = try std.fs.path.resolveAlloc(ctx.arena, &.{path});
            if (!contains(directories.items, directory)) try directories.append(ctx.arena, directory);

            var dir = try ctx.cwd.openDir(ctx.io, path, .{ .iterate = true });
            defer dir.close(ctx.io);

            var walker = try dir.walk(ctx.arena);
            defer walker.deinit();

            while (try walker.next(ctx.io)) |entry| {
                if (entry.kind != .file) continue;

                if (isSource(entry.path)) {
                    const file = try std.fs.path.resolveAlloc(ctx.arena, &.{ path, entry.path });
                    try files.append(ctx.arena, file);
                }
            }
        } else {
            if (!isSource(path)) {
                try ctx.err.print("source '{s}' has an unsupported file type\n", .{path});
                return error.AlreadyReported;
            }
            const file = try std.fs.path.resolveAlloc(ctx.arena, &.{path});
            try files.append(ctx.arena, file);
        }
    }

    std.mem.sort([]const u8, files.items, {}, lessThan);

    return .{
        .files = removeDuplicates(files.items),
        .directories = directories.items,
    };
}

fn contains(list: []const []const u8, path: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, path)) return true;
    }

    return false;
}

/// Moves the different files to the front of `files` and returns that part. `files` must be
/// sorted: equal paths are then next to each other, so comparing with the last kept one is enough.
fn removeDuplicates(files: [][]const u8) [][]const u8 {
    var count: usize = 0;
    for (files) |file| {
        if (count > 0 and std.mem.eql(u8, file, files[count - 1])) continue;

        files[count] = file;
        count += 1;
    }

    return files[0..count];
}

/// Determines valid file types. In case of adding new extensions, just the if statement should be extended with such.
fn isSource(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    if (std.mem.eql(u8, extension, ".c") or
        std.mem.eql(u8, extension, ".cc") or
        std.mem.eql(u8, extension, ".cpp") or
        std.mem.eql(u8, extension, ".cxx") or
        std.mem.eql(u8, extension, ".c++"))
    {
        return true;
    }

    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const testContext = context.testContext;

test "isSource: C and C++ extensions" {
    try testing.expect(isSource("main.c"));
    try testing.expect(isSource("main.cc"));
    try testing.expect(isSource("main.cpp"));
    try testing.expect(isSource("main.cxx"));
    try testing.expect(isSource("main.c++"));
}

test "isSource: only the last extension of the file name counts" {
    try testing.expect(isSource("src/net/http.c"));
    try testing.expect(isSource("parser.gen.cpp"));
    try testing.expect(!isSource("main.c.txt"));
    try testing.expect(!isSource("dir.c/README"));
}

test "isSource: everything else is not a source" {
    try testing.expect(!isSource("main.h"));
    try testing.expect(!isSource("main.hpp"));
    try testing.expect(!isSource("main.C")); // case-sensitive
    try testing.expect(!isSource("Makefile"));
    try testing.expect(!isSource(".c")); // a hidden file, not an extension
    try testing.expect(!isSource(""));
}

test "removeDuplicates: keeps one of each, in order" {
    var files = [_][]const u8{ "a.c", "a.c", "b.c", "c.c", "c.c", "c.c" };

    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "a.c", "b.c", "c.c" }),
        @as([]const []const u8, removeDuplicates(&files)),
    );
}

test "removeDuplicates: nothing to remove" {
    var files = [_][]const u8{ "a.c", "b.c" };

    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "a.c", "b.c" }),
        @as([]const []const u8, removeDuplicates(&files)),
    );
}

test "removeDuplicates: an empty list stays empty" {
    try testing.expectEqual(0, removeDuplicates(&.{}).len);
}

/// Creates empty files in `dir`, with the directories they need.
fn createFiles(dir: std.Io.Dir, paths: []const []const u8) !void {
    for (paths) |path| {
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(testing.io, parent);
        try dir.writeFile(testing.io, .{ .sub_path = path, .data = "" });
    }
}

/// `expand` returns paths in the system's own form: src/main.c, or src\main.c on Windows.
const main_c = "src" ++ std.fs.path.sep_str ++ "main.c";
const http_cpp = "src" ++ std.fs.path.sep_str ++ "net" ++ std.fs.path.sep_str ++ "http.cpp";

test "expand: a directory gives every source under it, sorted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try createFiles(tmp.dir, &.{ "src/net/http.cpp", "src/net/http.h", "src/main.c", "src/README", "other.c" });

    const sources = try expand(ctx, &.{"src/"});

    try testing.expectEqualDeep(@as([]const []const u8, &.{ main_c, http_cpp }), sources.files);
}

test "expand: a file gives itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try createFiles(tmp.dir, &.{ "src/main.c", "src/net/http.cpp" });

    const sources = try expand(ctx, &.{"src/main.c"});

    try testing.expectEqualDeep(@as([]const []const u8, &.{main_c}), sources.files);
    try testing.expectEqual(0, sources.directories.len); // only directory entries give -iquote
}

test "expand: a file found several times is returned once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try createFiles(tmp.dir, &.{ "src/main.c", "src/net/http.cpp" });

    const sources = try expand(ctx, &.{ "src/", "src", "./src", "src//net/", "src/main.c", "./src/main.c" });

    try testing.expectEqualDeep(@as([]const []const u8, &.{ main_c, http_cpp }), sources.files);
}

test "expand: each directory is returned once, in the order of sources" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try createFiles(tmp.dir, &.{ "src/net/http.cpp", "lib/util.c" });

    const sources = try expand(ctx, &.{ "src/net/", "src/", "./src", "lib", "lib/util.c" });

    const src_net = "src" ++ std.fs.path.sep_str ++ "net";
    try testing.expectEqualDeep(@as([]const []const u8, &.{ src_net, "src", "lib" }), sources.directories);
}

test "expand: a directory without sources gives nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try createFiles(tmp.dir, &.{"include/app.h"});

    const sources = try expand(ctx, &.{"include/"});

    try testing.expectEqual(0, sources.files.len);
}

test "expand: a missing path is reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();

    try testing.expectError(error.AlreadyReported, expand(ctx, &.{"src/"}));
    try testing.expectEqualStrings("source 'src/' not found\n", output.written());
}

test "expand: a named file that isn't a source is reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try createFiles(tmp.dir, &.{"notes.txt"});

    try testing.expectError(error.AlreadyReported, expand(ctx, &.{"notes.txt"}));
    try testing.expectEqualStrings("source 'notes.txt' has an unsupported file type\n", output.written());
}

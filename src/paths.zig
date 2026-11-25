const std = @import("std");
const context = @import("context.zig");
const Context = context.Context;

pub fn expand(ctx: Context, paths: []const []const u8) ![]const []const u8 {
    _ = ctx;
    _ = paths;
    return .{};
}

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

// ---------------------------------------------------------------- tests

const testing = std.testing;

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

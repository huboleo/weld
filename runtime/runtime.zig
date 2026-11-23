const std = @import("std");
const builtin = @import("builtin");

// Mirrors of the structs in include/weld/build.h. `extern struct` gives them
// the C layout, so the field order and types must match the header exactly.

/// `weld_strings`: `items` is null when the list was left empty. The entries
/// are optional too, so a NULL passed by the user can be reported, not read.
const WeldStrings = extern struct {
    items: ?[*]const ?[*:0]const u8,
    count: usize,
};

/// `weld_executable_options`: `name` is null when it was left out.
const ExecutableOptions = extern struct {
    name: ?[*:0]const u8,
    sources: WeldStrings,
    includes: WeldStrings,
};

/// `weld_library_options`
const LibraryOptions = extern struct {
    name: ?[*:0]const u8,
    sources: WeldStrings,
    includes: WeldStrings,
};

const Build = struct {
    arena: std.mem.Allocator,
};

extern fn build(b: *Build) void;

comptime {
    // The test runner has its own `main`, so ours is exported only outside tests.
    if (!builtin.is_test) @export(&main, .{ .name = "main" });
}

fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    _ = argc;
    _ = argv;

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var b: Build = .{ .arena = allocator };

    build(&b);

    return 0;
}

/// Fails when mirrored types in zig and original translated from
/// build.h differ in size, number of fields, or the offset of any field.
/// A field missing from Original is a compile error.
fn expectSameLayout(comptime Mirror: type, comptime Original: type) !void {
    const names = comptime std.meta.fieldNames(Mirror);
    try std.testing.expectEqual(std.meta.fieldNames(Original).len, names.len);
    try std.testing.expectEqual(@sizeOf(Original), @sizeOf(Mirror));
    inline for (names) |name| {
        try std.testing.expectEqual(@offsetOf(Original, name), @offsetOf(Mirror, name));
    }
}

test "mirrored types have the same layout as in build.h" {
    // build.h translated to Zig by translate-c (see build.zig).
    const c = @import("build_h");
    try expectSameLayout(WeldStrings, c.weld_strings);
    try expectSameLayout(ExecutableOptions, c.weld_executable_options);
    try expectSameLayout(LibraryOptions, c.weld_library_options);
}

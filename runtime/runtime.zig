const std = @import("std");

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

export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    _ = argc;
    _ = argv;

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var b: Build = .{ .arena = allocator };

    build(&b);

    return 0;
}

const std = @import("std");

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

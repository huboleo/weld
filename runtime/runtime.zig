const std = @import("std");
const builtin = @import("builtin");
const description = @import("description");

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

const Options = union(description.Target.Kind) {
    executable: ExecutableOptions,
    library: LibraryOptions,
};

const Build = struct {
    arena: std.mem.Allocator,
    /// Name for targets that leave .name out. Placeholder until weld passes it in argv.
    default_name: []const u8,
    targets: std.ArrayList(*description.Target) = .empty,
};

extern fn build(b: *Build) void;

comptime {
    // The test runner has its own `main`, so ours is exported only outside tests.
    if (!builtin.is_test) @export(&main, .{ .name = "main" });
}

fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    const args = argv[0..@intCast(argc)];

    var path: ?[:0]u8 = null;
    var i: usize = 1;

    while (i < args.len) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--out")) {
            if (i + 1 == args.len) {
                std.debug.print("--out needs a path\n", .{});
                return 1;
            }

            path = std.mem.span(args[i + 1]);
            i += 2;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return 1;
        }
    }

    const out = path orelse {
        std.debug.print("usage: {s} --out <path>\n", .{args[0]});
        return 1;
    };

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var b: Build = .{ .arena = allocator, .default_name = "app" };

    build(&b);

    const targets = b.arena.alloc(description.Target, b.targets.items.len) catch @panic("out of memory");

    for (b.targets.items, targets) |t, *slot| {
        slot.* = t.*;
    }

    const bytes = std.json.Stringify.valueAlloc(b.arena, description.Description{ .version = description.current_version, .targets = targets }, .{}) catch @panic("out of memory");

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = out,
        .data = bytes,
    }) catch |err| {
        std.debug.print("cannot write {s}: {t}\n", .{ out, err });
        return 1;
    };

    return 0;
}

fn addTarget(b: *Build, options: Options) !*description.Target {
    switch (options) {
        // Compiled once per kind: o is that kind's options struct, kind is known at compile time.
        inline else => |o, kind| {
            const function = "weld_add_" ++ @tagName(kind);

            const name = if (o.name) |n| try b.arena.dupe(u8, std.mem.span(n)) else b.default_name;

            var sources = try copyStrings(b.arena, o.sources, .{ .function = function, .target = name, .field = "sources" });
            if (sources.len == 0) sources = &.{"src/"};

            const includes = try copyStrings(b.arena, o.includes, .{ .function = function, .target = name, .field = "includes" });

            const target = try b.arena.create(description.Target);
            target.* = .{ .kind = kind, .name = name, .sources = sources, .includes = includes };
            try b.targets.append(b.arena, target);
            return target;
        },
    }
}

export fn weld_add_executable(b: *Build, options: ?*const ExecutableOptions) *description.Target {
    const o = options orelse fail("weld_add_executable: options is NULL", .{});
    return addTarget(b, .{ .executable = o.* }) catch @panic("out of memory");
}

export fn weld_add_library(b: *Build, options: ?*const LibraryOptions) *description.Target {
    const o = options orelse fail("weld_add_library: options is NULL", .{});
    return addTarget(b, .{ .library = o.* }) catch @panic("out of memory");
}

/// Copies a C list of strings into the arena, so nothing points into the
/// script's memory after the call. A null list gives an empty slice; a NULL
/// entry ends the script with an error message.
fn copyStrings(arena: std.mem.Allocator, list: WeldStrings, origin: Origin) ![]const []const u8 {
    const items = list.items orelse return &.{};

    const copy = try arena.alloc([]const u8, list.count);
    for (items[0..list.count], copy, 0..) |item, *slot, i| {
        const ptr = item orelse fail("{s}(\"{s}\"): {s}[{d}] is NULL", .{ origin.function, origin.target, origin.field, i });
        slot.* = try arena.dupe(u8, std.mem.span(ptr));
    }

    return copy;
}

/// Where a list came from, for error messages:
/// `weld_add_executable("app"): sources[1] is NULL`.
const Origin = struct {
    function: []const u8,
    target: []const u8,
    field: []const u8,
};

/// For mistakes in the build script: prints the message to stderr and exits
/// with code 1. weld shows the script's stderr to the user.
fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ "\n", args);
    std.process.exit(1);
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

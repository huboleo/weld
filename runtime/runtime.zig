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
    c_standard: c_uint,
    cpp_standard: c_uint,
};

/// `weld_library_options`
const LibraryOptions = extern struct {
    name: ?[*:0]const u8,
    sources: WeldStrings,
    includes: WeldStrings,
    c_standard: c_uint,
    cpp_standard: c_uint,
};

const Options = union(description.Target.Kind) {
    executable: ExecutableOptions,
    library: LibraryOptions,
};

const Build = struct {
    arena: std.mem.Allocator,
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
    var b: Build = .{ .arena = allocator };

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

            const raw_name = std.mem.span(o.name orelse "");
            if (raw_name.len == 0) {
                fail("{s}: name is missing", .{function});
            }
            if (!description.isValidName(raw_name)) {
                fail("{s}(\"{s}\"): a name may only contain letters, digits, '_', '-' and '.', and can't start with '.' or '-'", .{ function, raw_name });
            }

            for (b.targets.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing.name, raw_name)) {
                    fail("{s}(\"{s}\"): a target named \"{s}\" already exists", .{ function, raw_name, existing.name });
                }
            }

            const name = try b.arena.dupe(u8, raw_name);

            const sources = try copyStrings(b.arena, o.sources, .{ .function = function, .target = name, .field = "sources" });
            if (sources.len == 0) {
                fail("{s}(\"{s}\"): sources is missing", .{ function, name });
            }

            const includes = try copyStrings(b.arena, o.includes, .{ .function = function, .target = name, .field = "includes" });

            const c_standard = toStandard(description.CStandard, o.c_standard, .gnu17, .{ .function = function, .target = name, .field = "c_standard" });
            const cpp_standard = toStandard(description.CppStandard, o.cpp_standard, .@"c++23", .{ .function = function, .target = name, .field = "cpp_standard" });

            const target = try b.arena.create(description.Target);
            target.* = .{
                .kind = kind,
                .name = name,
                .sources = sources,
                .includes = includes,
                .c_standard = c_standard,
                .cpp_standard = cpp_standard,
            };
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

/// Turns the number a script passed into a standard. 0 means the script left
/// the field out and gives `default`; an unknown number ends the script with
/// an error message.
fn toStandard(comptime Standard: type, number: c_uint, default: Standard, origin: Origin) Standard {
    if (number == 0) return default;

    return std.enums.fromInt(Standard, number) orelse
        fail("{s}(\"{s}\"): {s} has an unknown value {d}", .{ origin.function, origin.target, origin.field, number });
}

/// Where a value came from, for error messages:
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

test "standards have the same numbers as in build.h" {
    const c = @import("build_h");
    const CStandard = description.CStandard;
    const CppStandard = description.CppStandard;

    try std.testing.expectEqual(CStandard.c99, std.enums.fromInt(CStandard, c.WELD_C_99));
    try std.testing.expectEqual(CStandard.c11, std.enums.fromInt(CStandard, c.WELD_C_11));
    try std.testing.expectEqual(CStandard.c17, std.enums.fromInt(CStandard, c.WELD_C_17));
    try std.testing.expectEqual(CStandard.c23, std.enums.fromInt(CStandard, c.WELD_C_23));
    try std.testing.expectEqual(CStandard.gnu99, std.enums.fromInt(CStandard, c.WELD_C_GNU99));
    try std.testing.expectEqual(CStandard.gnu11, std.enums.fromInt(CStandard, c.WELD_C_GNU11));
    try std.testing.expectEqual(CStandard.gnu17, std.enums.fromInt(CStandard, c.WELD_C_GNU17));
    try std.testing.expectEqual(CStandard.gnu23, std.enums.fromInt(CStandard, c.WELD_C_GNU23));

    try std.testing.expectEqual(CppStandard.@"c++11", std.enums.fromInt(CppStandard, c.WELD_CPP_11));
    try std.testing.expectEqual(CppStandard.@"c++14", std.enums.fromInt(CppStandard, c.WELD_CPP_14));
    try std.testing.expectEqual(CppStandard.@"c++17", std.enums.fromInt(CppStandard, c.WELD_CPP_17));
    try std.testing.expectEqual(CppStandard.@"c++20", std.enums.fromInt(CppStandard, c.WELD_CPP_20));
    try std.testing.expectEqual(CppStandard.@"c++23", std.enums.fromInt(CppStandard, c.WELD_CPP_23));

    // 0 means "not set", so it must not be a standard.
    try std.testing.expectEqual(null, std.enums.fromInt(CStandard, 0));
    try std.testing.expectEqual(null, std.enums.fromInt(CppStandard, 0));
}

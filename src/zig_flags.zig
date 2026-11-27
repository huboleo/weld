//! The flags clangd needs to read a file the way `zig cc` / `zig c++` compile it: the target,
//! and Zig's own libc and libc++ headers and defines. Zig doesn't list them anywhere, so they
//! come from a dry run (`-###`), which prints the clang command Zig would run.

const std = @import("std");
const builtin = @import("builtin");
const context = @import("context.zig");
const Context = context.Context;
const Language = context.Language;

/// The machine weld runs on, in Zig's target syntax, e.g. "aarch64-macos-none".
const host_target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi);

/// Where the dry run happens. It leaves an empty .o in its working directory, so it runs in a
/// folder of its own, which is deleted afterwards.
const probe_dir = "weld-out/zig-flags-probe";

/// clangd's flags, one set per language.
pub const Flags = struct {
    c_files: []const []const u8,
    cpp_files: []const []const u8,
};

/// Where the flags are kept between runs, with everything they depend on: which Zig (its version,
/// and where it's installed, because the paths are absolute) and the target.
const cache_path = "weld-out/zig-flags.json";

const Cache = struct {
    zig_version: []const u8,
    lib_dir: []const u8,
    target: []const u8,
    flags: Flags,
};

/// Returns clangd's flags for C and C++ files on the host. Zig is asked only when the cache is
/// missing or was made for a different Zig or target.
pub fn get(ctx: Context) !Flags {
    const env = try zigEnv(ctx);

    if (try readCache(ctx)) |cache| {
        if (std.mem.eql(u8, cache.zig_version, env.version) and
            std.mem.eql(u8, cache.lib_dir, env.lib_dir) and
            std.mem.eql(u8, cache.target, host_target))
        {
            return cache.flags;
        }
    }

    const flags: Flags = .{
        .c_files = try dryRun(ctx, .c, env.lib_dir),
        .cpp_files = try dryRun(ctx, .@"c++", env.lib_dir),
    };

    const cache: Cache = .{ .zig_version = env.version, .lib_dir = env.lib_dir, .target = host_target, .flags = flags };
    const json = try std.json.Stringify.valueAlloc(ctx.arena, cache, .{ .whitespace = .indent_2 });
    try ctx.cwd.createDirPath(ctx.io, "weld-out");
    try ctx.cwd.writeFile(ctx.io, .{ .sub_path = cache_path, .data = json });

    return flags;
}

/// The cache, or null if there is none or it can't be read. Then the flags are simply asked again.
fn readCache(ctx: Context) !?Cache {
    const bytes = ctx.cwd.readFileAlloc(ctx.io, cache_path, ctx.arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return std.json.parseFromSliceLeaky(Cache, ctx.arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
}

/// Runs Zig's dry run for `language` and returns clangd's flags from it (see `parse`).
fn dryRun(ctx: Context, language: Language, lib_dir: []const u8) ![]const []const u8 {
    try ctx.cwd.createDirPath(ctx.io, probe_dir);
    // Also when Zig fails. A folder that can't be deleted is only a leftover, not an error.
    defer ctx.cwd.deleteTree(ctx.io, probe_dir) catch {};
    // Defers run in reverse order, so the folder is closed before it's deleted (Windows needs that).
    var dir = try ctx.cwd.openDir(ctx.io, probe_dir, .{});
    defer dir.close(ctx.io);

    // Clang refuses a file that doesn't exist, even in a dry run.
    const probe = switch (language) {
        .c => "probe.c",
        .@"c++" => "probe.cpp",
    };
    try dir.writeFile(ctx.io, .{ .sub_path = probe, .data = "" });

    const argv: []const []const u8 = switch (language) {
        .c => &.{ "zig", "cc", "-target", host_target, "-###", "-c", "probe.c" },
        .@"c++" => &.{ "zig", "c++", "-target", host_target, "-###", "-c", "probe.cpp" },
    };
    const result = try std.process.run(ctx.arena, ctx.io, .{ .argv = argv, .cwd = .{ .dir = dir } });
    if (!result.term.success()) {
        try ctx.err.print("zig's dry run failed:\n{s}", .{result.stderr});
        return error.AlreadyReported;
    }

    // Clang prints the commands to stderr.
    const flags = try parse(ctx.arena, result.stderr, lib_dir);

    // Without these, clangd would add the system's own headers on top of Zig's. (Zig's command
    // has -nostdsysteminc for that, which clangd doesn't understand.)
    const no_system_headers: []const []const u8 = switch (language) {
        .c => &.{"-nostdlibinc"},
        .@"c++" => &.{ "-nostdlibinc", "-nostdinc++" },
    };

    return std.mem.concat(ctx.arena, []const u8, &.{ flags, no_system_headers });
}

/// What `zig env` tells about the Zig on the PATH. `parse` needs `lib_dir` to recognize Zig's
/// builtin headers.
const ZigEnv = struct {
    version: []const u8,
    lib_dir: []const u8,
};

fn zigEnv(ctx: Context) !ZigEnv {
    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "zig", "env" },
        .cwd = context.childCwd(ctx),
    });
    if (!result.term.success()) {
        try ctx.err.print("zig env failed:\n{s}", .{result.stderr});
        return error.AlreadyReported;
    }

    // `zig env` prints ZON. Its parser also handles escaped paths, like C:\\zig\\lib on Windows.
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(ZigEnv, .{
        .gpa = ctx.arena,
        .arena = ctx.arena,
        .source = try ctx.arena.dupeSentinel(u8, result.stdout, 0),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.ParseZon => {
            try ctx.err.print("can't read the output of zig env\n", .{});
            return error.AlreadyReported;
        },
        else => return err,
    };
}

/// Picks clangd's flags out of what `zig cc -###` prints: `-triple` as `--target=`, the
/// `-isystem` paths and the `-D` defines. `<lib_dir>/include` is left out: it holds Zig's copy of
/// clang's builtin headers, and clangd has to use its own. The result can point into `output`.
pub fn parse(arena: std.mem.Allocator, output: []const u8, lib_dir: []const u8) ![]const []const u8 {
    const command = findCommand(output) orelse return error.NoCompileCommand;
    const builtin_headers = try std.fs.path.join(arena, &.{ lib_dir, "include" });

    var flags: std.ArrayList([]const u8) = .empty;
    var arguments: Arguments = .{ .line = command };

    while (try arguments.next(arena)) |argument| {
        if (std.mem.eql(u8, argument, "-triple")) {
            const triple = try arguments.next(arena) orelse return error.MissingValue;
            try flags.append(arena, try std.mem.concat(arena, u8, &.{ "--target=", triple }));
        } else if (std.mem.eql(u8, argument, "-isystem")) {
            const path = try arguments.next(arena) orelse return error.MissingValue;
            if (std.mem.eql(u8, path, builtin_headers)) continue;
            try flags.appendSlice(arena, &.{ "-isystem", path });
        } else if (std.mem.eql(u8, argument, "-D")) {
            const define = try arguments.next(arena) orelse return error.MissingValue;
            try flags.appendSlice(arena, &.{ "-D", define });
        }
    }

    return flags.items;
}

/// The line with the real compile command. The lines before it are clang's version and target.
fn findCommand(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "\"-cc1\"") != null) return line;
    }

    return null;
}

/// Reads the arguments of a command printed by `-###`, one at a time. Clang puts each argument in
/// double quotes and escapes `"`, `\` and `$` inside them with a backslash.
const Arguments = struct {
    line: []const u8,
    index: usize = 0,

    fn next(self: *Arguments, arena: std.mem.Allocator) !?[]const u8 {
        const start = std.mem.findScalarPos(u8, self.line, self.index, '"') orelse return null;

        var end = start + 1;
        var escaped = false;
        while (end < self.line.len and self.line[end] != '"') : (end += 1) {
            if (self.line[end] == '\\') {
                escaped = true;
                end += 1; // the next character is taken as it is, even a quote
            }
        }
        if (end >= self.line.len) return error.UnterminatedArgument;

        self.index = end + 1;
        const raw = self.line[start + 1 .. end];

        // Only an argument with escapes needs a copy; all others point into the line.
        return if (escaped) try unescape(arena, raw) else raw;
    }
};

fn unescape(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const result = try arena.alloc(u8, raw.len);
    var len: usize = 0;
    var i: usize = 0;

    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') i += 1;
        result[len] = raw[i];
        len += 1;
    }

    return result[0..len];
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn contains(flags: []const []const u8, flag: []const u8) bool {
    for (flags) |f| {
        if (std.mem.eql(u8, f, flag)) return true;
    }

    return false;
}

// What `zig c++ -target aarch64-macos -### -c x.cpp` prints with Zig 0.17.1 from Homebrew,
// shortened: most code generation flags are cut out of the command.
const macos_cpp_output =
    \\Homebrew clang version 22.1.8
    \\Target: aarch64-apple-macosx15.0.0-unknown
    \\Thread model: posix
    \\InstalledDir: /opt/homebrew/Cellar/zig/0.17.1/bin
    \\ (in-process)
    \\ "/opt/homebrew/Cellar/zig/0.17.1/bin/zig" "-cc1" "-triple" "arm64-apple-macosx15.0.0-unknown" "-O0" "-emit-obj" "-target-cpu" "apple-m1" "-target-feature" "+neon" "-nostdsysteminc" "-nobuiltininc" "-resource-dir" "/opt/homebrew/Cellar/zig/0.17.1/lib/clang/22" "-isystem" "/opt/homebrew/Cellar/zig/0.17.1/lib/zig/libcxx/include" "-isystem" "/opt/homebrew/Cellar/zig/0.17.1/lib/zig/libcxxabi/include" "-isystem" "/opt/homebrew/Cellar/zig/0.17.1/lib/zig/include" "-isystem" "/opt/homebrew/Cellar/zig/0.17.1/lib/zig/libc/include/any-darwin-any" "-D" "_LIBCPP_ABI_VERSION=1" "-D" "_LIBCPP_HAS_THREADS=1" "-fcxx-exceptions" "-o" "x.o" "-x" "c++" "x.cpp"
    \\
;

test "parse: the target, Zig's header paths and defines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const flags = try parse(arena.allocator(), macos_cpp_output, "/opt/homebrew/Cellar/zig/0.17.1/lib/zig");

    try testing.expectEqualDeep(@as([]const []const u8, &.{
        "--target=arm64-apple-macosx15.0.0-unknown",
        "-isystem",
        "/opt/homebrew/Cellar/zig/0.17.1/lib/zig/libcxx/include",
        "-isystem",
        "/opt/homebrew/Cellar/zig/0.17.1/lib/zig/libcxxabi/include",
        // lib/zig/include is left out: clangd uses its own builtin headers.
        "-isystem",
        "/opt/homebrew/Cellar/zig/0.17.1/lib/zig/libc/include/any-darwin-any",
        "-D",
        "_LIBCPP_ABI_VERSION=1",
        "-D",
        "_LIBCPP_HAS_THREADS=1",
    }), flags);
}

test "parse: escaped characters inside an argument" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const output =
        \\ "zig" "-cc1" "-isystem" "/Users/me/my zig/lib/libc/include" "-D" "GREETING=\"hi\"" "-D" "PATH=C:\\zig"
    ;
    const flags = try parse(arena.allocator(), output, "/Users/me/my zig/lib");

    try testing.expectEqualDeep(@as([]const []const u8, &.{
        "-isystem",
        "/Users/me/my zig/lib/libc/include", // a space needs no escape inside the quotes
        "-D",
        "GREETING=\"hi\"",
        "-D",
        "PATH=C:\\zig",
    }), flags);
}

test "parse: output without a compile command is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // What `zig cc -###` prints when it isn't given a file.
    const output =
        \\Homebrew clang version 22.1.8
        \\Target: arm64-apple-darwin27.2.0
    ;
    try testing.expectError(error.NoCompileCommand, parse(arena.allocator(), output, "/zig/lib"));
}

test "get: runs Zig and returns the target and Zig's own headers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = context.testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();

    const lib_dir = (try zigEnv(ctx)).lib_dir;
    const builtin_headers = try std.fs.path.join(ctx.arena, &.{ lib_dir, "include" });
    const both = try get(ctx);

    for ([_]Language{ .c, .@"c++" }, [_][]const []const u8{ both.c_files, both.cpp_files }) |language, flags| {
        try testing.expect(std.mem.startsWith(u8, flags[0], "--target="));

        // The paths depend on where Zig is installed, so only where they point is checked.
        var headers: usize = 0;
        for (flags, 0..) |flag, i| {
            if (!std.mem.eql(u8, flag, "-isystem")) continue;
            const path = flags[i + 1];
            try testing.expect(std.mem.startsWith(u8, path, lib_dir));
            try testing.expect(!std.mem.eql(u8, path, builtin_headers));
            headers += 1;
        }
        try testing.expect(headers > 0);

        try testing.expect(contains(flags, "-nostdlibinc"));
        try testing.expectEqual(language == .@"c++", contains(flags, "-nostdinc++"));
    }

    // The dry run's empty .o never reached the project, and its folder is gone.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "probe.o", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, probe_dir, .{}));
}

/// Writes a cache file for the current Zig and the host, with `lib_dir` in place of Zig's own
/// and made-up flags.
fn writeTestCache(ctx: Context, lib_dir: []const u8) !void {
    const cache: Cache = .{
        .zig_version = (try zigEnv(ctx)).version,
        .lib_dir = lib_dir,
        .target = host_target,
        .flags = .{ .c_files = &.{"--cached-c"}, .cpp_files = &.{"--cached-cpp"} },
    };
    try ctx.cwd.createDirPath(ctx.io, "weld-out");
    try ctx.cwd.writeFile(ctx.io, .{
        .sub_path = cache_path,
        .data = try std.json.Stringify.valueAlloc(ctx.arena, cache, .{}),
    });
}

test "get: a cache for the same Zig and target is used, and Zig isn't asked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = context.testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    try writeTestCache(ctx, (try zigEnv(ctx)).lib_dir);

    const flags = try get(ctx);

    // Only the cache has these, so no dry run happened.
    try testing.expectEqualDeep(@as([]const []const u8, &.{"--cached-c"}), flags.c_files);
    try testing.expectEqualDeep(@as([]const []const u8, &.{"--cached-cpp"}), flags.cpp_files);
}

test "get: a cache for a Zig installed elsewhere is replaced" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = context.testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();
    // The same version, but another lib_dir: e.g. Homebrew's Zig and weld's own download.
    try writeTestCache(ctx, "/somewhere/else/lib");

    const flags = try get(ctx);

    try testing.expect(std.mem.startsWith(u8, flags.c_files[0], "--target="));
    const cache = (try readCache(ctx)).?;
    try testing.expectEqualStrings((try zigEnv(ctx)).lib_dir, cache.lib_dir);
    try testing.expectEqualDeep(flags, cache.flags);
}

test "parse: an argument without its closing quote is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.UnterminatedArgument, parse(arena.allocator(), " \"zig\" \"-cc1\" \"-D", "/zig/lib"));
}

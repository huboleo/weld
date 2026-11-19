const std = @import("std");
const Context = @import("cli.zig").Context;

const Language = enum { c, @"c++" };

const ProjectType = enum { executable, library };

const Options = struct {
    language: Language,
    project_type: ProjectType = .executable,
    git: bool = true,
};

pub fn run(ctx: Context, args: []const [:0]const u8) !void {
    const options = parseOptions(args) orelse {
        try ctx.err.print("invalid arguments. Run weld help init to see example usage\n", .{});
        return;
    };

    try createSrcDir(ctx);

    switch (options.project_type) {
        .library => {
            try createIncludeDir(ctx);
        },
        .executable => {
            try writeMainFile(ctx, options.language);
        },
    }

    try writeBuildScript(ctx, options.language, options.project_type);

    if (options.git) {
        try initGit(ctx);
    }
}

fn parseOptions(args: []const [:0]const u8) ?Options {
    if (args.len == 0) return null;

    const language = std.meta.stringToEnum(Language, args[0]) orelse return null;

    var options: Options = .{ .language = language };

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--lib")) {
            options.project_type = .library;
        } else if (std.mem.eql(u8, arg, "--no-git")) {
            options.git = false;
        } else {
            return null;
        }
    }

    return options;
}

fn createSrcDir(ctx: Context) !void {
    const status = try ctx.cwd.createDirPathStatus(ctx.io, "src", .default_dir);
    switch (status) {
        .created => try ctx.out.print("created /src directory\n", .{}),
        .existed => try ctx.out.print("src/ already exists\n", .{}),
    }
}

fn createIncludeDir(ctx: Context) !void {
    const status = try ctx.cwd.createDirPathStatus(ctx.io, "include", .default_dir);
    switch (status) {
        .created => try ctx.out.print("created include/\n", .{}),
        .existed => try ctx.out.print("include/ already exists\n", .{}),
    }
}

fn writeBuildScript(ctx: Context, language: Language, project_type: ProjectType) !void {
    const build_file: []const u8 = switch (language) {
        .c => "build.c",
        .@"c++" => "build.cpp",
    };

    const template: []const u8 = switch (language) {
        .c => switch (project_type) {
            .executable => @embedFile("templates/build_exe.c"),
            .library => @embedFile("templates/build_lib.c"),
        },
        .@"c++" => switch (project_type) {
            .executable => @embedFile("templates/build_exe.cpp"),
            .library => @embedFile("templates/build_lib.cpp"),
        },
    };

    ctx.cwd.writeFile(ctx.io, .{
        .sub_path = build_file,
        .data = template,
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try ctx.out.print("{s} already exists\n", .{build_file});
            return;
        },
        else => return err,
    };

    try ctx.out.print("created {s}\n", .{build_file});
}

fn writeMainFile(ctx: Context, language: Language) !void {
    const main_file: []const u8 = switch (language) {
        .c => "src/main.c",
        .@"c++" => "src/main.cpp",
    };

    const template: []const u8 = switch (language) {
        .c => @embedFile("templates/main.c"),
        .@"c++" => @embedFile("templates/main.cpp"),
    };

    ctx.cwd.writeFile(ctx.io, .{
        .sub_path = main_file,
        .data = template,
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try ctx.out.print("{s} already exists\n", .{main_file});
            return;
        },
        else => return err,
    };

    try ctx.out.print("created {s}\n", .{main_file});
}

fn initGit(ctx: Context) !void {
    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "git", "init" },
    });

    if (!result.term.success()) {
        try ctx.err.print("git init failed: {s}", .{result.stderr});
        return;
    }

    try ctx.out.print("initialized git repository\n", .{});

    try writeGitignore(ctx);
}

fn writeGitignore(ctx: Context) !void {
    ctx.cwd.writeFile(ctx.io, .{
        .sub_path = ".gitignore",
        .data = @embedFile("templates/gitignore"),
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try ctx.out.print(".gitignore already exists, make sure it contains /weld-out/\n", .{});
            return;
        },
        else => return err,
    };

    try ctx.out.print("created .gitignore\n", .{});
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testContext(dir: std.Io.Dir, writer: *std.Io.Writer) Context {
    return .{
        .io = testing.io,
        .arena = testing.allocator,
        .cwd = dir,
        .out = writer,
        .err = writer,
    };
}

test "parseOptions: language only gives the defaults" {
    const options = parseOptions(&.{"c"}).?;
    try testing.expectEqual(Language.c, options.language);
    try testing.expectEqual(ProjectType.executable, options.project_type);
    try testing.expectEqual(true, options.git);
}

test "parseOptions: flags change the defaults" {
    const options = parseOptions(&.{ "c++", "--lib", "--no-git" }).?;
    try testing.expectEqual(Language.@"c++", options.language);
    try testing.expectEqual(ProjectType.library, options.project_type);
    try testing.expectEqual(false, options.git);
}

test "parseOptions: invalid arguments give null" {
    try testing.expect(parseOptions(&.{}) == null);
    try testing.expect(parseOptions(&.{"rust"}) == null);
    try testing.expect(parseOptions(&.{ "c", "--foo" }) == null);
    try testing.expect(parseOptions(&.{ "--lib", "c" }) == null);
}

test "createSrcDir: creates src/ and accepts an existing one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try createSrcDir(ctx);
    try createSrcDir(ctx);

    try tmp.dir.access(testing.io, "src", .{});
}

test "writeBuildScript: writes the template for the language and project type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try writeBuildScript(ctx, .@"c++", .library);

    const content = try tmp.dir.readFileAlloc(testing.io, "build.cpp", testing.allocator, .limited(4096));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(@embedFile("templates/build_lib.cpp"), content);
}

test "writeBuildScript: never overwrites an existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.c", .data = "mine" });
    try writeBuildScript(ctx, .c, .executable);

    const content = try tmp.dir.readFileAlloc(testing.io, "build.c", testing.allocator, .limited(4096));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("mine", content);
    try testing.expectEqualStrings("build.c already exists\n", output.written());
}

test "writeGitignore: ignores weld-out" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try writeGitignore(ctx);

    const content = try tmp.dir.readFileAlloc(testing.io, ".gitignore", testing.allocator, .limited(4096));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("/weld-out/\n", content);
}

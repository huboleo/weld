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
        return error.AlreadyReported;
    };

    const other_build_file: []const u8 = switch (options.language) {
        .c => "build.cpp",
        .@"c++" => "build.c",
    };
    if (try fileExists(ctx, other_build_file)) {
        try ctx.err.print("{s} already exists, a project can't have both build.c and build.cpp\n", .{other_build_file});
        return error.AlreadyReported;
    }

    switch (options.project_type) {
        .library => {
            const project_name = resolveProjectName(ctx) catch |err| switch (err) {
                error.EmptyProjectName => {
                    try ctx.err.print("project name can't be empty\n", .{});
                    return error.AlreadyReported;
                },
                else => return err,
            };

            const ident = transformNameIntoIdentifier(ctx.arena, project_name) catch |err| switch (err) {
                error.InvalidIdentifier => {
                    try ctx.err.print("project name '{s}' can't start with a digit\n", .{project_name});
                    return error.AlreadyReported;
                },
                else => return err,
            };

            try createDir(ctx, "src");

            const include_path = try std.fs.path.join(ctx.arena, &.{ "include", project_name });
            try createDir(ctx, include_path);

            var include_template: []const u8 = undefined;
            var src_template: []const u8 = undefined;
            var src_file_extension: []const u8 = undefined;
            var include_file_extension: []const u8 = undefined;

            switch (options.language) {
                .c => {
                    include_template = @embedFile("templates/lib.h");
                    src_template = @embedFile("templates/lib.c");
                    src_file_extension = ".c";
                    include_file_extension = ".h";
                },
                .@"c++" => {
                    include_template = @embedFile("templates/lib.hpp");
                    src_template = @embedFile("templates/lib.cpp");
                    src_file_extension = ".cpp";
                    include_file_extension = ".hpp";
                },
            }

            const include_file_name = try std.mem.concat(ctx.arena, u8, &.{ project_name, include_file_extension });
            const src_file_name = try std.mem.concat(ctx.arena, u8, &.{ project_name, src_file_extension });

            const include_file_content = try fillTemplate(ctx.arena, include_template, project_name, ident);
            const src_file_content = try fillTemplate(ctx.arena, src_template, project_name, ident);

            const include_file_path = try std.fs.path.join(ctx.arena, &.{ include_path, include_file_name });
            const src_file_path = try std.fs.path.join(ctx.arena, &.{ "src", src_file_name });

            _ = try writeNewFile(ctx, include_file_path, include_file_content);
            _ = try writeNewFile(ctx, src_file_path, src_file_content);
        },
        .executable => {
            try createDir(ctx, "src");
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

/// Creates the directory at `path`, including any missing parent directories. An existing
/// directory is fine. Prints what happened.
fn createDir(ctx: Context, path: []const u8) !void {
    const status = try ctx.cwd.createDirPathStatus(ctx.io, path, .default_dir);
    switch (status) {
        .created => try ctx.out.print("created {s}/\n", .{path}),
        .existed => try ctx.out.print("{s}/ already exists\n", .{path}),
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

    _ = try writeNewFile(ctx, build_file, template);
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

    _ = try writeNewFile(ctx, main_file, template);
}

fn initGit(ctx: Context) !void {
    // Spawning a program that isn't on PATH fails with FileNotFound.
    const inside_repo = isInsideGitRepo(ctx) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.err.print("git not found, skipping git init\n", .{});
            return;
        },
        else => return err,
    };

    if (inside_repo) {
        try ctx.out.print("already inside a git repository, skipping git init\n", .{});
    } else {
        const result = try std.process.run(ctx.arena, ctx.io, .{
            .argv = &.{ "git", "init" },
        });

        if (!result.term.success()) {
            try ctx.err.print("git init failed: {s}", .{result.stderr});
            return error.AlreadyReported;
        }

        try ctx.out.print("initialized git repository\n", .{});
    }

    try writeGitignore(ctx);
}

/// `git rev-parse` succeeds only inside an existing work tree; outside one it exits with 128.
fn isInsideGitRepo(ctx: Context) !bool {
    const result = try std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "git", "rev-parse", "--is-inside-work-tree" },
    });
    return result.term.success();
}

fn fileExists(ctx: Context, path: []const u8) !bool {
    ctx.cwd.access(ctx.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn writeGitignore(ctx: Context) !void {
    const created = try writeNewFile(ctx, ".gitignore", @embedFile("templates/gitignore"));
    if (!created) {
        try ctx.out.print("make sure .gitignore contains /weld-out/\n", .{});
    }
}

fn resolveProjectName(ctx: Context) ![]const u8 {
    const full_path = try ctx.cwd.realPathFileAlloc(ctx.io, ".", ctx.arena);
    const lib_name = std.fs.path.basename(full_path);

    if (lib_name.len == 0) {
        return error.EmptyProjectName;
    }

    return lib_name;
}

fn transformNameIntoIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.ascii.isDigit(name[0])) {
        return error.InvalidIdentifier;
    }

    const ident = try allocator.dupe(u8, name);

    for (ident) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '_') {
            c.* = '_';
        }
    }

    return ident;
}

/// Writes `content` to `path` unless the file already exists; existing files are never
/// overwritten. Prints what happened and returns true if the file was created.
fn writeNewFile(ctx: Context, path: []const u8, content: []const u8) !bool {
    ctx.cwd.writeFile(ctx.io, .{
        .sub_path = path,
        .data = content,
        .flags = .{ .exclusive = true },
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try ctx.out.print("{s} already exists\n", .{path});
            return false;
        },
        else => return err,
    };

    try ctx.out.print("created {s}\n", .{path});
    return true;
}

fn fillTemplate(allocator: std.mem.Allocator, template: []const u8, name: []const u8, ident: []const u8) ![]u8 {
    const with_name = try std.mem.replaceOwned(u8, allocator, template, "WELD_NAME", name);
    defer allocator.free(with_name);

    return std.mem.replaceOwned(u8, allocator, with_name, "WELD_IDENT", ident);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const testContext = @import("cli.zig").testContext;

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

test "createDir: creates nested directories and accepts existing ones" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try createDir(ctx, "include/mylib");
    try createDir(ctx, "include/mylib");

    try tmp.dir.access(testing.io, "include/mylib", .{});
    try testing.expectEqualStrings(
        "created include/mylib/\ninclude/mylib/ already exists\n",
        output.written(),
    );
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

test "transformNameIntoIdentifier: replaces characters that are not allowed in C" {
    const cases = [_][2][]const u8{
        .{ "mylib", "mylib" },
        .{ "my-lib", "my_lib" },
        .{ "my.lib", "my_lib" },
        .{ "my lib", "my_lib" },
        .{ "my_lib2", "my_lib2" },
    };

    for (cases) |case| {
        const ident = try transformNameIntoIdentifier(testing.allocator, case[0]);
        defer testing.allocator.free(ident);
        try testing.expectEqualStrings(case[1], ident);
    }
}

test "transformNameIntoIdentifier: a leading digit is an error" {
    try testing.expectError(error.InvalidIdentifier, transformNameIntoIdentifier(testing.allocator, "2048-game"));
}

test "fillTemplate: replaces both placeholders everywhere" {
    const result = try fillTemplate(
        testing.allocator,
        "#include <WELD_NAME/WELD_NAME.h>\nvoid WELD_IDENT_say_hello(void);",
        "my-lib",
        "my_lib",
    );
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("#include <my-lib/my-lib.h>\nvoid my_lib_say_hello(void);", result);
}

test "resolveProjectName: gives the name of the directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project_dir = try tmp.dir.createDirPathOpen(testing.io, "my-lib", .{});
    defer project_dir.close(testing.io);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(project_dir, &output.writer);
    ctx.arena = arena.allocator();

    try testing.expectEqualStrings("my-lib", try resolveProjectName(ctx));
}

test "writeMainFile: writes src/main.cpp for C++" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try createDir(ctx, "src");
    try writeMainFile(ctx, .@"c++");

    const content = try tmp.dir.readFileAlloc(testing.io, "src/main.cpp", testing.allocator, .limited(4096));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(@embedFile("templates/main.cpp"), content);
}

test "run: a C library project gets a filled header and source" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project_dir = try tmp.dir.createDirPathOpen(testing.io, "my-lib", .{});
    defer project_dir.close(testing.io);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(project_dir, &output.writer);
    ctx.arena = arena.allocator();

    try run(ctx, &.{ "c", "--lib", "--no-git" });

    const header = try project_dir.readFileAlloc(testing.io, "include/my-lib/my-lib.h", testing.allocator, .limited(4096));
    defer testing.allocator.free(header);
    try testing.expect(std.mem.indexOf(u8, header, "void my_lib_say_hello(void);") != null);

    const source = try project_dir.readFileAlloc(testing.io, "src/my-lib.c", testing.allocator, .limited(4096));
    defer testing.allocator.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "#include <my-lib/my-lib.h>") != null);

    try project_dir.access(testing.io, "build.c", .{});
}

test "run: a library name starting with a digit creates nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var project_dir = try tmp.dir.createDirPathOpen(testing.io, "2048-game", .{});
    defer project_dir.close(testing.io);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(project_dir, &output.writer);
    ctx.arena = arena.allocator();

    try testing.expectError(error.AlreadyReported, run(ctx, &.{ "c", "--lib", "--no-git" }));

    try testing.expectEqualStrings("project name '2048-game' can't start with a digit\n", output.written());
    try testing.expectError(error.FileNotFound, project_dir.access(testing.io, "src", .{}));
    try testing.expectError(error.FileNotFound, project_dir.access(testing.io, "build.c", .{}));
}

test "run: an existing build script for the other language creates nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.cpp", .data = "" });

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try testing.expectError(error.AlreadyReported, run(ctx, &.{ "c", "--no-git" }));

    try testing.expectEqualStrings("build.cpp already exists, a project can't have both build.c and build.cpp\n", output.written());
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "src", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "build.c", .{}));
}

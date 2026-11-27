const std = @import("std");
const description = @import("description");
const context = @import("context.zig");
const script = @import("script.zig");
const compile_commands = @import("compile_commands.zig");
const zig_flags = @import("zig_flags.zig");
const Context = context.Context;
const Language = context.Language;
const fileExists = context.fileExists;
const childCwd = context.childCwd;

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

    const directory_name = resolveProjectName(ctx) catch |err| switch (err) {
        error.EmptyProjectName => {
            try ctx.err.print("project name can't be empty\n", .{});
            return error.AlreadyReported;
        },
        else => return err,
    };

    const project_name = toValidName(ctx.arena, directory_name) catch |err| switch (err) {
        error.NonAscii => {
            try ctx.err.print("directory name '{s}' contains non-ASCII characters, rename the directory\n", .{directory_name});
            return error.AlreadyReported;
        },
        error.InvalidStart => {
            try ctx.err.print("directory name '{s}' can't start with '.' or '-', rename the directory\n", .{directory_name});
            return error.AlreadyReported;
        },
        error.EmptyProjectName => {
            try ctx.err.print("directory name '{s}' has no letters or digits, rename the directory\n", .{directory_name});
            return error.AlreadyReported;
        },
        else => return err,
    };
    if (!std.mem.eql(u8, project_name, directory_name)) {
        try ctx.out.print("note: '{s}' isn't a valid target name, using '{s}'\n", .{ directory_name, project_name });
    }

    switch (options.project_type) {
        .library => {
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

    try writeBuildScript(ctx, options.language, options.project_type, project_name);

    // Runs the new build script once, so clangd works in the project right away.
    try writeClangd(ctx);
    try writeClangFormat(ctx, options.language);
    try writeClangTidy(ctx);
    const desc = try script.describe(ctx);
    try compile_commands.write(ctx, desc, try zig_flags.get(ctx));
    try ctx.out.print("wrote weld-out/compile_commands.json\n", .{});

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

fn writeBuildScript(ctx: Context, language: Language, project_type: ProjectType, project_name: []const u8) !void {
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

    const content = try std.mem.replaceOwned(u8, ctx.arena, template, "WELD_NAME", project_name);
    _ = try writeNewFile(ctx, build_file, content);
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
            .cwd = childCwd(ctx),
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
        .cwd = childCwd(ctx),
    });
    return result.term.success();
}

fn writeClangd(ctx: Context) !void {
    _ = try writeNewFile(ctx, ".clangd", @embedFile("templates/clangd"));
}

/// One style for the whole project, picked by its language. clang-format can tell C from C++
/// files, but it counts every .h as C++, so a C project's headers would get the C++ style.
fn writeClangFormat(ctx: Context, language: Language) !void {
    const template = switch (language) {
        .c => @embedFile("templates/clang-format-c"),
        .@"c++" => @embedFile("templates/clang-format-cpp"),
    };
    _ = try writeNewFile(ctx, ".clang-format", template);
}

/// The same checks for C and C++: the C++-only ones don't apply to C files.
fn writeClangTidy(ctx: Context) !void {
    _ = try writeNewFile(ctx, ".clang-tidy", @embedFile("templates/clang-tidy"));
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

/// Turns a directory name into a valid target name, slug style: `my  project (copy)` becomes
/// `my-project-copy`. A valid name is returned unchanged. Non-ASCII characters and a leading `.`
/// or `-` can't be fixed without guessing, so they are errors.
fn toValidName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (description.isValidName(name)) return name;
    if (std.mem.startsWith(u8, name, ".") or std.mem.startsWith(u8, name, "-")) return error.InvalidStart;

    const slug = try allocator.alloc(u8, name.len);
    var len: usize = 0;
    // Set by `-` and every character a name doesn't allow. The `-` is written only before the
    // next allowed character, so a run of them becomes one `-`, and none is left at either end.
    var separator = false;

    for (name) |character| {
        if (!std.ascii.isAscii(character)) return error.NonAscii;

        if (std.ascii.isAlphanumeric(character) or character == '_' or character == '.') {
            if (separator and len > 0) {
                slug[len] = '-';
                len += 1;
            }
            separator = false;
            slug[len] = character;
            len += 1;
        } else {
            separator = true;
        }
    }

    if (len == 0) return error.EmptyProjectName;
    // E.g. ` .app`: the space is dropped, and the name would start with `.`.
    if (!description.isValidName(slug[0..len])) return error.InvalidStart;

    return slug[0..len];
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

const testContext = context.testContext;

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

test "writeBuildScript: writes the template for the language and project type, with the project's name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();

    try writeBuildScript(ctx, .@"c++", .library, "shapes");

    const content = try tmp.dir.readFileAlloc(testing.io, "build.cpp", testing.allocator, .limited(4096));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(
        \\#include <weld/build.hpp>
        \\
        \\void build(weld::Build& b) {
        \\    b.add_library({
        \\        .name = "shapes",
        \\        .sources = {"src/"},
        \\        .includes = {"include/"},
        \\        .cpp_standard = weld::CppStandard::cpp23,
        \\    });
        \\}
        \\
    , content);
}

test "writeBuildScript: never overwrites an existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = testContext(tmp.dir, &output.writer);
    ctx.arena = arena.allocator();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build.c", .data = "mine" });
    try writeBuildScript(ctx, .c, .executable, "shapes");

    const content = try tmp.dir.readFileAlloc(testing.io, "build.c", testing.allocator, .limited(4096));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("mine", content);
    try testing.expectEqualStrings("build.c already exists\n", output.written());
}

test "writeClangFormat: C projects get char *p, C++ projects char* p" {
    for ([_]Language{ .c, .@"c++" }, [_][]const u8{ "PointerAlignment: Right", "PointerAlignment: Left" }) |language, alignment| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        const ctx = testContext(tmp.dir, &output.writer);

        try writeClangFormat(ctx, language);

        const content = try tmp.dir.readFileAlloc(testing.io, ".clang-format", testing.allocator, .limited(4096));
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, alignment) != null);
        // A single style for the whole file: no per-language sections, which older formatters reject.
        try testing.expect(std.mem.indexOf(u8, content, "Language:") == null);
    }
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

test "toValidName: turns other ASCII characters into -, one for each run" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_][2][]const u8{
        .{ "my-lib", "my-lib" }, // already valid: unchanged
        .{ "a--b", "a--b" }, // valid too, so its dashes are kept
        .{ "my project", "my-project" },
        .{ "my  project", "my-project" },
        .{ "a - b", "a-b" },
        .{ "project (copy)", "project-copy" },
        .{ " app ", "app" }, // nothing left at either end
        .{ "c++ tools", "c-tools" },
    };

    for (cases) |case| {
        const name = try toValidName(arena.allocator(), case[0]);
        try testing.expectEqualStrings(case[1], name);
        try testing.expect(description.isValidName(name));
    }
}

test "toValidName: what can't be fixed without guessing is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectError(error.NonAscii, toValidName(allocator, "zażółć"));
    try testing.expectError(error.InvalidStart, toValidName(allocator, ".hidden"));
    try testing.expectError(error.InvalidStart, toValidName(allocator, "-app"));
    try testing.expectError(error.InvalidStart, toValidName(allocator, " .app"));
    try testing.expectError(error.EmptyProjectName, toValidName(allocator, "(!)"));
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

    const clangd = try project_dir.readFileAlloc(testing.io, ".clangd", testing.allocator, .limited(4096));
    defer testing.allocator.free(clangd);
    try testing.expectEqualStrings(@embedFile("templates/clangd"), clangd);

    const clang_tidy = try project_dir.readFileAlloc(testing.io, ".clang-tidy", testing.allocator, .limited(8192));
    defer testing.allocator.free(clang_tidy);
    try testing.expectEqualStrings(@embedFile("templates/clang-tidy"), clang_tidy);

    // The new build script was run: the script and the library's source both have an entry.
    const commands = try project_dir.readFileAlloc(testing.io, "weld-out/compile_commands.json", testing.allocator, .unlimited);
    defer testing.allocator.free(commands);
    try testing.expect(std.mem.indexOf(u8, commands, "\"file\": \"build.c\"") != null);
    const my_lib_c = "src" ++ std.fs.path.sep_str ++ "my-lib.c";
    try testing.expect(std.mem.indexOf(u8, commands, "\"file\": \"" ++ my_lib_c ++ "\"") != null);

    // Zig's flags reached the entries, so clangd reads them with Zig's headers.
    try testing.expect(std.mem.indexOf(u8, commands, "\"--target=") != null);
    try testing.expect(std.mem.indexOf(u8, commands, "\"-nostdlibinc\"") != null);
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

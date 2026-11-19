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

fn writeBuildScript(ctx: Context, language: Language, project_type: ProjectType) !void {
    const build_file: []const u8 = switch (language) {
        .c => "build.c",
        .@"c++" => "build.cpp",
    };

    const template: []const u8 = switch (language) {
        .c => switch (project_type) {
            .executable => build_c_exec_template,
            .library => build_c_lib_template,
        },
        .@"c++" => switch (project_type) {
            .executable => build_cpp_exec_template,
            .library => build_cpp_lib_template,
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
        .data = gitignore_template,
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

const gitignore_template =
    \\/weld-out/
    \\
;

const build_c_exec_template =
    \\// weld build script (C). Placeholder until weld.h exists.
    \\
;

const build_cpp_exec_template =
    \\// weld build script (C++). Placeholder until weld.hpp exists.
    \\
;

const build_c_lib_template =
    \\// weld build script (C). Placeholder until weld.h exists.
    \\
;

const build_cpp_lib_template =
    \\// weld build script (C++). Placeholder until weld.hpp exists.
    \\
;

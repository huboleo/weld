const std = @import("std");
const Io = std.Io;

pub const Context = struct {
    io: Io,
    arena: std.mem.Allocator,
    cwd: Io.Dir,
    out: *Io.Writer,
    err: *Io.Writer,
};

pub const CommandType = enum { init, build, run, @"test", lint, fmt, help };

pub const Command = struct {
    type: CommandType,
    args: []const [:0]const u8,
};

pub fn parse(args: []const [:0]const u8) !Command {
    if (args.len == 0) {
        return error.MissingCommand;
    }

    const cmd_type = std.meta.stringToEnum(CommandType, args[0]) orelse return error.UnknownCommand;

    const command = Command{ .type = cmd_type, .args = args[1..] };

    return command;
}

pub fn runCommand(ctx: Context, args: []const [:0]const u8) !void {
    const cmd = parse(args[1..]) catch |err| switch (err) {
        error.MissingCommand => {
            try ctx.err.print("Missing command. Example usage:\n{s}", .{usage});
            return;
        },
        error.UnknownCommand => {
            try ctx.err.print("Unknown command. Example usage:\n{s}", .{usage});
            return;
        },
    };

    switch (cmd.type) {
        .init => {
            try runInit(ctx, cmd.args);
        },
        .build => {
            return;
        },
        .run => {
            return;
        },
        .@"test" => {
            return;
        },
        .lint => {
            return;
        },
        .fmt => {
            return;
        },
        .help => {
            return;
        },
    }
}

const Language = enum { c, @"c++" };

fn runInit(ctx: Context, args: []const [:0]const u8) !void {
    if (args.len != 1) {
        try ctx.err.print("invalid arguments. Run weld help init to see example usage\n", .{});
        return;
    }

    const language = std.meta.stringToEnum(Language, args[0]) orelse {
        try ctx.err.print("invalid arguments. Run weld help init to see example usage\n", .{});
        return;
    };

    const status = try ctx.cwd.createDirPathStatus(ctx.io, "src", .default_dir);
    switch (status) {
        .created => try ctx.out.print("created /src directory\n", .{}),
        .existed => try ctx.out.print("src/ already exists\n", .{}),
    }

    const build_file: []const u8 = switch (language) {
        .c => "build.c",
        .@"c++" => "build.cpp",
    };

    const template: []const u8 = switch (language) {
        .c => build_c_template,
        .@"c++" => build_cpp_template,
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

const build_c_template =
    \\// weld build script (C). Placeholder until weld.h exists.
    \\
;

const build_cpp_template =
    \\// weld build script (C++). Placeholder until weld.hpp exists.
    \\
;

const usage =
    \\weld <command> [options]
    \\ 
    \\commands:
    \\  init    Initialize project
    \\  build   Build the project
    \\  run     Build, then run executable
    \\  test    Run tests
    \\  lint    Run clang-tidy
    \\  fmt     Run clang-format 
    \\  help    Prints commands with their options
    \\
;

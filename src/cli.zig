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

fn runInit(ctx: Context, args: []const [:0]const u8) !void {
    if (args.len != 1 or !(std.mem.eql(u8, args[0], "c") or std.mem.eql(u8, args[0], "c++"))) {
        //return error.InvalidArguments;
        try ctx.err.print("invalid arguments. Run weld help init to see example usage\n", .{});
        return;
    }

    const status = try ctx.cwd.createDirPathStatus(ctx.io, "src", .default_dir);
    switch (status) {
        .created => try ctx.out.print("created /src directory\n", .{}),
        .existed => try ctx.out.print("src/ already exists\n", .{}),
    }
}

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

const std = @import("std");
const Io = std.Io;
const init = @import("init.zig");

pub const Context = struct {
    io: Io,
    arena: std.mem.Allocator,
    cwd: Io.Dir,
    out: *Io.Writer,
    err: *Io.Writer,
};

/// A Context for tests: files go to `dir`, and both output streams to `writer`.
pub fn testContext(dir: Io.Dir, writer: *Io.Writer) Context {
    return .{
        .io = std.testing.io,
        .arena = std.testing.allocator,
        .cwd = dir,
        .out = writer,
        .err = writer,
    };
}

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
            return error.AlreadyReported;
        },
        error.UnknownCommand => {
            try ctx.err.print("Unknown command. Example usage:\n{s}", .{usage});
            return error.AlreadyReported;
        },
    };

    switch (cmd.type) {
        .init => {
            try init.run(ctx, cmd.args);
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

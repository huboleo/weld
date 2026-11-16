const std = @import("std");
const Io = std.Io;

pub const Command = enum { init, build, run, @"test", lint, fmt };

pub fn parse(args: []const [:0]const u8) !Command {
    if (args.len == 0) {
        return error.MissingCommand;
    }

    return std.meta.stringToEnum(Command, args[0]) orelse error.UnknownCommand;
}

pub fn runCommand(writer: *Io.Writer, args: []const [:0]const u8) !void {
    const cmd = parse(args[1..]) catch |err| switch (err) {
        error.MissingCommand => {
            try writer.print("Missing command. Example usage:\n{s}", .{usage});
            return;
        },
        error.UnknownCommand => {
            try writer.print("Unknown command. Example usage:\n{s}", .{usage});
            return;
        },
    };

    try writer.print("{t}\n", .{cmd});
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
    \\
;

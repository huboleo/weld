const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    var stderr_file_writer: Io.File.Writer = .initStreaming(.stderr(), io, &.{});

    const ctx: cli.Context = .{
        .io = io,
        .arena = init.arena.allocator(),
        .cwd = Io.Dir.cwd(),
        .out = &stdout_file_writer.interface,
        .err = &stderr_file_writer.interface,
    };

    defer ctx.out.flush() catch {};

    // Commands print their own error message and return error.Reported, so here it only
    // becomes exit code 1. Any other error is unexpected and keeps Zig's error trace.
    cli.runCommand(ctx, args) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };

    return 0;
}

test {
    _ = @import("init.zig");
}

const std = @import("std");
const Io = std.Io;

const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &.{});

    const ctx: cli.Context = .{
        .io = io,
        .arena = init.arena.allocator(),
        .cwd = Io.Dir.cwd(),
        .out = &stdout_file_writer.interface,
        .err = &stderr_file_writer.interface,
    };

    defer ctx.out.flush() catch {};

    try cli.runCommand(ctx, args);
}

test {
    _ = @import("init.zig");
}

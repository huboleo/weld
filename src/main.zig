const std = @import("std");
const Io = std.Io;

const weld = @import("weld");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    try cli.runCommand(stdout_writer, args);
    try stdout_writer.flush();
}

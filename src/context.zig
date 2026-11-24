//! What every command works with: the Context, and small helpers shared
//! between commands.

const std = @import("std");
const Io = std.Io;

pub const Context = struct {
    io: Io,
    arena: std.mem.Allocator,
    cwd: Io.Dir,
    out: *Io.Writer,
    err: *Io.Writer,
};

/// The language of a project, and so of its build script (`build.c` or `build.cpp`).
pub const Language = enum { c, @"c++" };

/// Whether `path` exists relative to `ctx.cwd`. Errors other than "not found"
/// (e.g. no permission) are returned, not treated as "doesn't exist".
pub fn fileExists(ctx: Context, path: []const u8) !bool {
    ctx.cwd.access(ctx.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

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

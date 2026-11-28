//! What every command works with: the Context, and small helpers shared
//! between commands.

const std = @import("std");
const Io = std.Io;

pub const Context = struct {
    io: Io,
    arena: std.mem.Allocator,
    cwd: Io.Dir,
    environ: *const std.process.Environ.Map,
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

/// The working directory for child processes: the same as `ctx.cwd`.
/// `Io.Dir.cwd()` isn't a real handle (on POSIX it's the special value
/// AT_FDCWD), and passing it as `.dir` makes spawning panic with BADF, so it
/// becomes `.inherit` instead.
pub fn childCwd(ctx: Context) std.process.Child.Cwd {
    return if (ctx.cwd.handle == Io.Dir.cwd().handle) .inherit else .{ .dir = ctx.cwd };
}

/// No environment variables at all, for tests that don't set any.
const empty_environ: std.process.Environ.Map = .init(std.testing.allocator);

/// A Context for tests: files go to `dir`, and both output streams to `writer`.
pub fn testContext(dir: Io.Dir, writer: *Io.Writer) Context {
    return .{
        .io = std.testing.io,
        .arena = std.testing.allocator,
        .cwd = dir,
        .environ = &empty_environ,
        .out = writer,
        .err = writer,
    };
}

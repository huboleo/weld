const std = @import("std");
const Context = @import("context.zig").Context;

const runtime_lib = @embedFile("libweld_runtime.a");
const build_h = @embedFile("weld/build.h");

// Where the runtime is written, inside the project.
const runtime_include_dir = "weld-out/runtime/include"; // passed to -I
const runtime_header_dir = runtime_include_dir ++ "/weld"; // so <weld/build.h> resolves
const runtime_header_path = runtime_header_dir ++ "/build.h";
const runtime_lib_dir = "weld-out/runtime/lib";
const runtime_lib_path = runtime_lib_dir ++ "/libweld_runtime.a";

/// Writes the embedded runtime and its header into the project, where the
/// compiler can read them.
fn writeRuntime(ctx: Context) !void {
    try ctx.cwd.createDirPath(ctx.io, runtime_header_dir);
    try ctx.cwd.writeFile(ctx.io, .{ .sub_path = runtime_header_path, .data = build_h });

    try ctx.cwd.createDirPath(ctx.io, runtime_lib_dir);
    try ctx.cwd.writeFile(ctx.io, .{ .sub_path = runtime_lib_path, .data = runtime_lib });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const testContext = @import("context.zig").testContext;

test "writeRuntime: writes the header and the library where the compiler expects them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const ctx = testContext(tmp.dir, &output.writer);

    try writeRuntime(ctx);

    const lib = try tmp.dir.readFileAlloc(testing.io, runtime_lib_path, testing.allocator, .unlimited);
    defer testing.allocator.free(lib);
    // Every static library (ar archive) starts with this signature.
    try testing.expect(std.mem.startsWith(u8, lib, "!<arch>\n"));

    const header = try tmp.dir.readFileAlloc(testing.io, runtime_header_path, testing.allocator, .unlimited);
    defer testing.allocator.free(header);
    try testing.expectEqualStrings(build_h, header);
}

const std = @import("std");
const zig_release = @import("zig_release");
const builtin = @import("builtin");

pub fn weldHome(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("WELD_HOME")) |weld_home| {
        if (weld_home.len > 0) return weld_home;
    }

    switch (builtin.os.tag) {
        .macos => {
            const home = environ.get("HOME") orelse return error.HomeNotFound;
            if (home.len == 0) return error.HomeNotFound;

            return std.fs.path.join(arena, &.{ home, "Library", "Application Support", "weld" });
        },
        .windows => {
            const localappdata = environ.get("LOCALAPPDATA") orelse return error.HomeNotFound;
            if (localappdata.len == 0) return error.HomeNotFound;

            return std.fs.path.join(arena, &.{ localappdata, "weld" });
        },
        else => {
            if (environ.get("XDG_DATA_HOME")) |data_home| {
                if (data_home.len > 0) return std.fs.path.join(arena, &.{ data_home, "weld" });
            }

            const home = environ.get("HOME") orelse return error.HomeNotFound;
            if (home.len == 0) return error.HomeNotFound;

            return std.fs.path.join(arena, &.{
                home,
                ".local",
                "share",
                "weld",
            });
        },
    }
}

/// What weldHome gives on the OS the tests run on, with HOME and LOCALAPPDATA from testEnviron.
const test_os_folder = switch (builtin.os.tag) {
    .macos => "/home/me/Library/Application Support/weld",
    .windows => "C:\\Users\\me\\AppData\\Local\\weld",
    else => "/home/me/.local/share/weld",
};

/// An environment with the home variables of every OS, so the same test works on all of them.
fn testEnviron() !std.process.Environ.Map {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    errdefer environ.deinit();
    try environ.put("HOME", "/home/me");
    try environ.put("LOCALAPPDATA", "C:\\Users\\me\\AppData\\Local");
    return environ;
}

test "weldHome: the folder of this OS" {
    var environ = try testEnviron();
    defer environ.deinit();

    const home = try weldHome(std.testing.allocator, &environ);
    defer std.testing.allocator.free(home);
    try std.testing.expectEqualStrings(test_os_folder, home);
}

test "weldHome: WELD_HOME wins over the folder of the OS" {
    var environ = try testEnviron();
    defer environ.deinit();
    try environ.put("WELD_HOME", "/opt/weld");

    // Returned as it is, not allocated, so there's nothing to free.
    try std.testing.expectEqualStrings("/opt/weld", try weldHome(std.testing.allocator, &environ));
}

test "weldHome: an empty WELD_HOME counts as not set" {
    var environ = try testEnviron();
    defer environ.deinit();
    try environ.put("WELD_HOME", "");

    const home = try weldHome(std.testing.allocator, &environ);
    defer std.testing.allocator.free(home);
    try std.testing.expectEqualStrings(test_os_folder, home);
}

test "weldHome: XDG_DATA_HOME comes first on Linux and the BSDs" {
    if (builtin.os.tag == .macos or builtin.os.tag == .windows) return error.SkipZigTest;

    var environ = try testEnviron();
    defer environ.deinit();
    try environ.put("XDG_DATA_HOME", "/data");

    const home = try weldHome(std.testing.allocator, &environ);
    defer std.testing.allocator.free(home);
    try std.testing.expectEqualStrings("/data/weld", home);
}

test "weldHome: an error when the variable it needs is missing" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();

    try std.testing.expectError(error.HomeNotFound, weldHome(std.testing.allocator, &environ));
}

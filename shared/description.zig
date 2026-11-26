//! The build description: what a build script declares. The runtime writes it
//! as JSON, and weld reads it back. Used by runtime/ and src/.

const std = @import("std");

/// Bumped when the shape below changes, so weld can tell that a cached
/// description came from a different runtime and rerun the script.
pub const current_version: u32 = 1;

pub const Description = struct {
    /// No default on purpose: a file without it fails to parse instead of
    /// silently counting as the current version.
    version: u32,
    targets: []const Target,
};

pub const Target = struct {
    kind: Kind,
    name: []const u8,
    sources: []const []const u8,
    includes: []const []const u8,
    c_standard: CStandard,
    cpp_standard: CppStandard,

    pub const Kind = enum { executable, library };
};

// The names are the values of the compiler's -std flag. The numbers are the ones in build.h, where
// 0 means that the script didn't choose a standard.

pub const CStandard = enum(c_uint) {
    c99 = 1,
    c11,
    c17,
    c23,
    gnu99,
    gnu11,
    gnu17,
    gnu23,
};

pub const CppStandard = enum(c_uint) {
    @"c++11" = 1,
    @"c++14",
    @"c++17",
    @"c++20",
    @"c++23",
};

/// Whether `name` can be a target's name: only letters, digits, `_`, `-` and `.`, and no `.` or
/// `-` at the start. Names become paths in weld-out/, so this keeps them out of other directories
/// (`../foo`, `a/b`) and rules out `.` and `..`. A leading `-` would look like a flag on the
/// command line (`weld build -app`) and to the compiler.
pub fn isValidName(name: []const u8) bool {
    for (name) |character| {
        if (std.ascii.isAlphanumeric(character)) continue;

        switch (character) {
            '_', '-', '.' => continue,
            else => return false,
        }
    }

    return !std.mem.startsWith(u8, name, ".") and !std.mem.startsWith(u8, name, "-");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "isValidName: letters, digits, _, - and ." {
    try testing.expect(isValidName("app"));
    try testing.expect(isValidName("Shapes2"));
    try testing.expect(isValidName("my_lib-v1.2"));
    try testing.expect(isValidName("a.")); // a dot is fine after the start
}

test "isValidName: names that would leave weld-out/" {
    try testing.expect(!isValidName("../foo"));
    try testing.expect(!isValidName("a/b"));
    try testing.expect(!isValidName("a\\b")); // Windows separator
    try testing.expect(!isValidName("."));
    try testing.expect(!isValidName(".."));
}

test "isValidName: a dot or a dash at the start is not allowed" {
    try testing.expect(!isValidName(".hidden"));
    try testing.expect(!isValidName("-app")); // looks like a flag
    try testing.expect(isValidName("a-")); // a dash is fine after the start
}

test "isValidName: everything else is not allowed" {
    try testing.expect(!isValidName("my project"));
    try testing.expect(!isValidName("c:app"));
    try testing.expect(!isValidName("zażółć")); // only ASCII letters
}

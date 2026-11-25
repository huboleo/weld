//! The build description: what a build script declares. The runtime writes it
//! as JSON, and weld reads it back. Used by runtime/ and src/.

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

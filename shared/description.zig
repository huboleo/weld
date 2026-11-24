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

    pub const Kind = enum { executable, library };
};

const std = @import("std");
const context = @import("context.zig");
const description = @import("description");
const paths = @import("paths.zig");

const Context = context.Context;
const Description = description.Description;

const Entry = struct {
    directory: []const u8,
    file: []const u8,
    arguments: []const []const u8,
};

pub fn write(ctx: Context, desc: Description) !void {}

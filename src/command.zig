// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const config = @import("config.zig");

pub const max_config_bytes = 1024 * 1024;

pub const LoadedConfig = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    value: config.Config,

    pub fn deinit(self: LoadedConfig) void {
        self.allocator.free(self.bytes);
    }
};

pub fn loadAndValidate(io: std.Io, allocator: std.mem.Allocator, path: []const u8, stderr: *std.Io.Writer) !LoadedConfig {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_config_bytes));
    return switch (config.parse(bytes)) {
        .config => |value| .{ .allocator = allocator, .bytes = bytes, .value = value },
        .diagnostic => |diag| {
            try stderr.print("{s}:{d}: {s}: {s}\n", .{
                path,
                diag.line,
                @tagName(diag.reason),
                diag.key,
            });
            allocator.free(bytes);
            return error.InvalidConfiguration;
        },
    };
}

pub fn validate(io: std.Io, allocator: std.mem.Allocator, path: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const loaded = try loadAndValidate(io, allocator, path, stderr);
    defer loaded.deinit();
    try stdout.print("{s}: valid MTS v0.2 configuration\n", .{path});
}

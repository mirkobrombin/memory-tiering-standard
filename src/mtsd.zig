// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const command = @import("command.zig");

fn usage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll(
        "usage: mtsd --validate <mts.conf>\n" ++
            "       mtsd apply <mts.conf>\n",
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};
    if (args.len != 3) {
        try usage(stderr);
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, args[1], "--validate")) return command.validate(init.io, allocator, args[2], stdout, stderr);
    if (!std.mem.eql(u8, args[1], "apply")) {
        try usage(stderr);
        return error.InvalidArguments;
    }

    const loaded = try command.loadAndValidate(init.io, allocator, args[2], stderr);
    defer loaded.deinit();
    const device = std.Io.Dir.openFileAbsolute(init.io, "/dev/mts", .{ .mode = .read_write }) catch |err| {
        try stderr.print(
            "/dev/mts: {s}; refusing to pretend the configuration was applied\n",
            .{@errorName(err)},
        );
        return error.KernelMtsUnavailable;
    };
    defer device.close(init.io);

    // Applying tiers becomes legal only when the kernel exports the frozen ioctl.
    // Failing closed here keeps boot orchestration from masquerading as admission.
    return error.KernelIoctlNotImplemented;
}

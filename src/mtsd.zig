// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const command = @import("command.zig");
const config = @import("config.zig");
const uapi = @import("linux_uapi.zig");

fn usage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll(
        "usage: mtsd --validate <mts.conf>\n" ++
            "       mtsd apply <mts.conf>\n" ++
            "       mtsd run <mts.conf>\n",
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
    const apply_once = std.mem.eql(u8, args[1], "apply");
    const run = std.mem.eql(u8, args[1], "run");
    if (!apply_once and !run) {
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
    var retained_fds: [config.max_tiers]i32 = undefined;
    var retained_count: usize = 0;
    defer {
        for (retained_fds[0..retained_count]) |fd| _ = std.os.linux.close(fd);
    }

    for (loaded.value.tiers[0..loaded.value.tier_count]) |tier| {
        if (apply_once and tier.lifetime.? == .fd_scoped) {
            try stderr.print("tier {s}: fd-scoped lifetime requires `mtsd run`\n", .{tier.name});
            return error.FdScopedTierRequiresDaemon;
        }
        const provider = std.Io.Dir.openFileAbsolute(init.io, tier.provider, .{ .mode = .read_write }) catch |err| {
            try stderr.print("tier {s}: provider {s}: {s}\n", .{ tier.name, tier.provider, @errorName(err) });
            return error.ProviderUnavailable;
        };
        const mtsfd = uapi.registerTier(device.handle, provider.handle, tier) catch |err| {
            provider.close(init.io);
            try stderr.print("tier {s}: registration failed: {s}\n", .{ tier.name, @errorName(err) });
            return err;
        };
        provider.close(init.io);
        if (tier.lifetime.? == .fd_scoped) {
            retained_fds[retained_count] = mtsfd;
            retained_count += 1;
        } else _ = std.os.linux.close(mtsfd);
        try stdout.print("tier {s}: registered\n", .{tier.name});
    }

    if (loaded.value.mode == .enforce or loaded.value.domain_count != 0) {
        try stderr.writeAll("domain admission UAPI is unavailable; refusing partial application\n");
        return error.KernelDomainIoctlNotImplemented;
    }
    if (run) while (true) try std.Io.sleep(init.io, .fromSeconds(60), .awake);
}

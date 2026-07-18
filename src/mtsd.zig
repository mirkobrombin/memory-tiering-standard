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
    var retained_fds: [config.max_tiers + config.max_domains]i32 = undefined;
    var retained_count: usize = 0;
    var tier_fds: [config.max_tiers]i32 = undefined;
    defer {
        for (retained_fds[0..retained_count]) |fd| _ = std.os.linux.close(fd);
    }

    for (loaded.value.tiers[0..loaded.value.tier_count], 0..) |tier, tier_index| {
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
        tier_fds[tier_index] = mtsfd;
        retained_fds[retained_count] = mtsfd;
        retained_count += 1;
        try stdout.print("tier {s}: registered\n", .{tier.name});
    }

    for (loaded.value.domains[0..loaded.value.domain_count]) |domain| {
        if (domain.mode.? != .enforce) continue;
        if (!run) {
            try stderr.print("domain {s}: admission lifetime requires `mtsd run`\n", .{domain.path});
            return error.AdmittedDomainRequiresDaemon;
        }
        var domain_tier_fds: [8]i32 = undefined;
        var domain_tier_count: usize = 0;
        var names = std.mem.splitScalar(u8, domain.tiers, ',');
        while (names.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t");
            if (std.mem.eql(u8, name, "dram")) continue;
            for (loaded.value.tiers[0..loaded.value.tier_count], 0..) |tier, index| {
                if (!std.mem.eql(u8, name, tier.name)) continue;
                if (domain_tier_count == domain_tier_fds.len) return error.TooManyDomainTiers;
                domain_tier_fds[domain_tier_count] = tier_fds[index];
                domain_tier_count += 1;
                break;
            }
        }
        const cgroup_path = try std.fmt.allocPrint(allocator, "/sys/fs/cgroup{s}", .{domain.path});
        const cgroup = std.Io.Dir.openDirAbsolute(init.io, cgroup_path, .{}) catch |err| {
            try stderr.print("domain {s}: cgroup unavailable: {s}\n", .{ domain.path, @errorName(err) });
            return error.CgroupUnavailable;
        };
        const domain_fd = uapi.admitDomain(
            device.handle,
            cgroup.handle,
            domain_tier_fds[0..domain_tier_count],
            domain,
        ) catch |err| {
            cgroup.close(init.io);
            try stderr.print("domain {s}: admission failed: {s}\n", .{ domain.path, @errorName(err) });
            return err;
        };
        cgroup.close(init.io);
        retained_fds[retained_count] = domain_fd;
        retained_count += 1;
        try stdout.print("domain {s}: ADMITTED\n", .{domain.path});
    }
    if (run) while (true) try std.Io.sleep(init.io, .fromSeconds(60), .awake);
}

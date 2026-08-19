// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const config = @import("config.zig");
const uapi = @import("backend.zig");

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

pub fn applyConfig(io: std.Io, allocator: std.mem.Allocator, loaded: LoadedConfig, run: bool, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const apply_once = !run;
    const device = std.Io.Dir.openFileAbsolute(io, "/dev/mts", .{ .mode = .read_write }) catch |err| {
        try stderr.print(
            "/dev/mts: {s}; refusing to pretend the configuration was applied\n",
            .{@errorName(err)},
        );
        return error.KernelMtsUnavailable;
    };
    defer device.close(io);
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
        const provider = std.Io.Dir.openFileAbsolute(io, tier.provider, .{ .mode = .read_write }) catch |err| {
            try stderr.print("tier {s}: provider {s}: {s}\n", .{ tier.name, tier.provider, @errorName(err) });
            return error.ProviderUnavailable;
        };
        const mtsfd = uapi.registerTier(io, device.handle, provider.handle, tier) catch |err| {
            provider.close(io);
            try stderr.print("tier {s}: registration failed: {s}\n", .{ tier.name, @errorName(err) });
            return err;
        };
        provider.close(io);
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
        const cgroup = std.Io.Dir.openDirAbsolute(io, cgroup_path, .{}) catch |err| {
            try stderr.print("domain {s}: cgroup unavailable: {s}\n", .{ domain.path, @errorName(err) });
            return error.CgroupUnavailable;
        };
        const domain_fd = uapi.admitDomain(
            io,
            device.handle,
            cgroup.handle,
            domain_tier_fds[0..domain_tier_count],
            domain,
        ) catch |err| {
            cgroup.close(io);
            try stderr.print("domain {s}: admission failed: {s}\n", .{ domain.path, @errorName(err) });
            return err;
        };
        cgroup.close(io);
        retained_fds[retained_count] = domain_fd;
        retained_count += 1;
        try stdout.print("domain {s}: ADMITTED\n", .{domain.path});
    }
    if (run) while (true) try std.Io.sleep(io, .fromSeconds(60), .awake);
}

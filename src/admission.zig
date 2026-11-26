// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const config = @import("config.zig");

pub const Resource = enum { capacity, read_bandwidth, write_bandwidth, queue_slots };

pub const Shortfall = struct {
    domain: []const u8,
    tier: []const u8,
    resource: Resource,
    requested: u64,
    available: u64,
};

const Reserved = struct {
    capacity: u64 = 0,
    read_bandwidth: u64 = 0,
    write_bandwidth: u64 = 0,
    queue_slots: u64 = 0,
};

pub fn headroom(value: u64) ?u64 {
    const scaled = std.math.mul(u64, value, 6) catch return null;
    return std.math.divCeil(u64, scaled, 5) catch unreachable;
}

pub fn check(cfg: *const config.Config) ?Shortfall {
    var reserved = [_]Reserved{.{}} ** config.max_tiers;
    for (cfg.domains[0..cfg.domain_count]) |domain| {
        if (domain.mode.? != .enforce) continue;
        var names = std.mem.splitScalar(u8, domain.tiers, ',');
        while (names.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t");
            if (std.mem.eql(u8, name, "dram")) continue;
            const index = tierIndex(cfg, name) orelse continue;
            const tier = cfg.tiers[index];
            const taken = &reserved[index];
            const wants = [_]struct { Resource, u64, u64, *u64 }{
                .{ .capacity, domain.reserve_capacity_bytes, tier.capacity_bytes, &taken.capacity },
                .{ .read_bandwidth, domain.reserve_read_bandwidth_bytes_s, tier.read_bandwidth_bytes_s, &taken.read_bandwidth },
                .{ .write_bandwidth, domain.reserve_write_bandwidth_bytes_s, tier.write_bandwidth_bytes_s, &taken.write_bandwidth },
                .{ .queue_slots, domain.reserve_queue_slots, tier.max_inflight_batches, &taken.queue_slots },
            };
            for (wants) |want| {
                const resource, const request, const limit, const used = want;
                const available = limit -| used.*;
                const charged = headroom(request) orelse std.math.maxInt(u64);
                if (charged > available or (resource != .capacity and limit == 0)) return .{
                    .domain = domain.path,
                    .tier = name,
                    .resource = resource,
                    .requested = charged,
                    .available = available,
                };
            }
            for (wants) |want| {
                _, const request, _, const used = want;
                used.* += headroom(request).?;
            }
        }
    }
    return null;
}

pub fn unit(resource: Resource) []const u8 {
    return switch (resource) {
        .capacity => "bytes",
        .read_bandwidth, .write_bandwidth => "B/s",
        .queue_slots => "queue slots",
    };
}

fn tierIndex(cfg: *const config.Config, name: []const u8) ?usize {
    for (cfg.tiers[0..cfg.tier_count], 0..) |tier, index| {
        if (std.mem.eql(u8, tier.name, name)) return index;
    }
    return null;
}

const base =
    \\[MTS]
    \\Version=2
    \\Mode=enforce
    \\
    \\[Tier "cold"]
    \\UUID=018f4a10-0000-7dd2-a400-5104720c0001
    \\Kind=persistent-local-memory
    \\Provider=/var/lib/mts/cold.img
    \\Flags=fd-scoped
    \\CapacityBytes=1073741824
    \\ReadLatencyP50NSec=15000
    \\ReadLatencyP99NSec=100000
    \\WriteLatencyP50NSec=20000
    \\WriteLatencyP99NSec=200000
    \\ReadBandwidthBytesPerSec=500000000
    \\WriteBandwidthBytesPerSec=
;

const domain_section =
    \\
    \\MaxBatchPages=256
    \\MaxInflightBatches=8
    \\
    \\[Domain "/"]
    \\Mode=enforce
    \\Tiers=dram,cold
    \\FaultServiceP99USec=500
    \\ReuseHorizonUSec=1000000
    \\ReserveCapacityBytes=536870912
    \\ReserveReadBandwidthBytesPerSec=100000000
    \\ReserveWriteBandwidthBytesPerSec=100000000
    \\ReserveQueueSlots=4
    \\
;

var test_buffer: [2048]u8 = undefined;

fn parsed(write_bandwidth: []const u8, extra: []const u8) !config.Config {
    const text = try std.fmt.bufPrint(&test_buffer, "{s}{s}{s}{s}", .{ base, write_bandwidth, domain_section, extra });
    return switch (config.parse(text)) {
        .config => |cfg| cfg,
        .diagnostic => error.InvalidConfiguration,
    };
}

test "headroom matches the kernel's one fifth margin" {
    try std.testing.expectEqual(@as(?u64, 120000000), headroom(100000000));
    try std.testing.expectEqual(@as(?u64, 2), headroom(1));
    try std.testing.expectEqual(@as(?u64, 0), headroom(0));
    try std.testing.expectEqual(@as(?u64, null), headroom(std.math.maxInt(u64)));
}

test "a reservation that fits is admitted" {
    const cfg = try parsed("400000000", "");
    try std.testing.expectEqual(@as(?Shortfall, null), check(&cfg));
}

test "a tier slower than the reservation is reported" {
    const cfg = try parsed("14533145", "");
    const shortfall = check(&cfg).?;
    try std.testing.expectEqualStrings("/", shortfall.domain);
    try std.testing.expectEqualStrings("cold", shortfall.tier);
    try std.testing.expectEqual(Resource.write_bandwidth, shortfall.resource);
    try std.testing.expectEqual(@as(u64, 120000000), shortfall.requested);
    try std.testing.expectEqual(@as(u64, 14533145), shortfall.available);
}

test "the headroom alone can exhaust a tier" {
    const cfg = try parsed("110000000", "");
    try std.testing.expectEqual(Resource.write_bandwidth, check(&cfg).?.resource);
}

test "domains share a tier in configuration order" {
    const second =
        \\
        \\[Domain "/user.slice"]
        \\Mode=enforce
        \\Tiers=dram,cold
        \\FaultServiceP99USec=500
        \\ReuseHorizonUSec=1000000
        \\ReserveCapacityBytes=268435456
        \\ReserveReadBandwidthBytesPerSec=100000000
        \\ReserveWriteBandwidthBytesPerSec=100000000
        \\ReserveQueueSlots=2
        \\
    ;
    const cfg = try parsed("200000000", second);
    const shortfall = check(&cfg).?;
    try std.testing.expectEqualStrings("/user.slice", shortfall.domain);
    try std.testing.expectEqual(@as(u64, 80000000), shortfall.available);
}

test "observed domains reserve nothing" {
    const observed =
        \\
        \\[Domain "/user.slice"]
        \\Mode=observe
        \\Tiers=dram,cold
        \\
    ;
    const cfg = try parsed("400000000", observed);
    try std.testing.expectEqual(@as(?Shortfall, null), check(&cfg));
}

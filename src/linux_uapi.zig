// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const config = @import("config.zig");

pub const version: u16 = 2;
pub const tier_flag_persistent: u32 = 1;
pub const tier_flag_fd_scoped: u32 = 2;

pub const TierDesc = extern struct {
    version: u16,
    kind: u16,
    flags: u32,
    uuid: [16]u8,
    capacity_bytes: u64,
    allocation_granule_bytes: u64,
    read_latency_p50_ns: u64,
    read_latency_p99_ns: u64,
    write_latency_p50_ns: u64,
    write_latency_p99_ns: u64,
    read_bandwidth_bytes_s: u64,
    write_bandwidth_bytes_s: u64,
    write_cost_nj_per_kib: u64,
    endurance_cost_ppb_per_kib: u64,
    volatility_class: u32,
    failure_domain: u32,
    max_batch_pages: u32,
    max_inflight_batches: u32,
    confidentiality_caps: u32,
    compression_size_classes: u16,
    compression_leakage_bits_q8: u16,
    completion_release_quantum_ns: u64,
    reserved: [8]u64,
};

pub const RegisterTier = extern struct {
    version: u16,
    size: u16,
    reserved0: u32,
    tier: TierDesc,
    provider_fd: i32,
    mtsfd: i32,
    reserved: [6]u64,
};

const register_ioctl = std.os.linux.IOCTL.IOWR(0xbc, 0x01, RegisterTier);

pub fn descriptor(tier: config.Tier) !TierDesc {
    return .{
        .version = version,
        .kind = try tierKind(tier.kind),
        .flags = switch (tier.lifetime.?) {
            .persistent => tier_flag_persistent,
            .fd_scoped => tier_flag_fd_scoped,
        },
        .uuid = try parseUuid(tier.uuid),
        .capacity_bytes = tier.capacity_bytes,
        .allocation_granule_bytes = 4096,
        // Unknown capabilities remain maximally pessimistic until mtsd has
        // measured a service curve. They must never look like zero cost.
        .read_latency_p50_ns = std.math.maxInt(u64),
        .read_latency_p99_ns = std.math.maxInt(u64),
        .write_latency_p50_ns = std.math.maxInt(u64),
        .write_latency_p99_ns = std.math.maxInt(u64),
        .read_bandwidth_bytes_s = 0,
        .write_bandwidth_bytes_s = 0,
        .write_cost_nj_per_kib = std.math.maxInt(u64),
        .endurance_cost_ppb_per_kib = std.math.maxInt(u64),
        .volatility_class = std.math.maxInt(u32),
        .failure_domain = std.math.maxInt(u32),
        .max_batch_pages = 1,
        .max_inflight_batches = 1,
        .confidentiality_caps = 0,
        .compression_size_classes = 0,
        .compression_leakage_bits_q8 = std.math.maxInt(u16),
        .completion_release_quantum_ns = std.math.maxInt(u64),
        .reserved = @splat(0),
    };
}

pub fn registerTier(control_fd: i32, provider_fd: i32, tier: config.Tier) !i32 {
    var request = RegisterTier{
        .version = version,
        .size = @sizeOf(RegisterTier),
        .reserved0 = 0,
        .tier = try descriptor(tier),
        .provider_fd = provider_fd,
        .mtsfd = -1,
        .reserved = @splat(0),
    };
    const result = std.os.linux.ioctl(control_fd, register_ioctl, @intFromPtr(&request));
    if (std.os.linux.errno(result) != .SUCCESS) return error.RegisterTierFailed;
    if (request.mtsfd < 0) return error.InvalidTierDescriptor;
    return request.mtsfd;
}

fn tierKind(value: []const u8) !u16 {
    const values = [_][]const u8{
        "dram",          "compressed-memory", "persistent-local-memory", "cxl-memory",
        "local-storage", "remote-memory",     "legacy-swap",
    };
    for (values, 0..) |candidate, index| {
        if (std.mem.eql(u8, value, candidate)) return @intCast(index);
    }
    return error.InvalidTierKind;
}

fn parseUuid(text: []const u8) ![16]u8 {
    var output: [16]u8 = undefined;
    var byte_index: usize = 0;
    var high: ?u8 = null;
    for (text) |char| {
        if (char == '-') continue;
        const nibble = std.fmt.charToDigit(char, 16) catch return error.InvalidUuid;
        if (high) |first| {
            if (byte_index == output.len) return error.InvalidUuid;
            output[byte_index] = first << 4 | nibble;
            byte_index += 1;
            high = null;
        } else high = nibble;
    }
    if (byte_index != output.len or high != null) return error.InvalidUuid;
    return output;
}

test "Zig registration layout matches the frozen 64-bit UAPI" {
    try std.testing.expectEqual(@as(usize, 200), @sizeOf(TierDesc));
    try std.testing.expectEqual(@as(usize, 264), @sizeOf(RegisterTier));
    try std.testing.expectEqual(@as(u32, 0xc108bc01), register_ioctl);
}

test "UUID text maps to stable network-order bytes" {
    const uuid = try parseUuid("018f3f28-7ee0-7dd2-a400-8f847e14c001");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x8f, 0x3f, 0x28 }, uuid[0..4]);
    try std.testing.expectEqual(@as(u8, 0x01), uuid[15]);
}

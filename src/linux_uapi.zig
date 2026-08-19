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

pub const TierReservation = extern struct {
    tier_fd: i32,
    reserved0: u32 = 0,
    capacity_bytes: u64,
    read_bandwidth_bytes_s: u64,
    write_bandwidth_bytes_s: u64,
    queue_slots: u32,
    reserved1: u32 = 0,
};

pub const AdmitDomain = extern struct {
    version: u16,
    size: u16,
    flags: u32,
    cgroup_fd: i32,
    domain_fd: i32,
    fault_service_p99_ns: u64,
    reuse_horizon_us: u64,
    reservations_ptr: u64,
    reservation_count: u32,
    status: u32,
    stable_cgroup_id: u64,
    reserved: [6]u64,
};

const register_ioctl = std.os.linux.IOCTL.IOWR(0xbc, 0x01, RegisterTier);
const admit_ioctl = std.os.linux.IOCTL.IOWR(0xbc, 0x04, AdmitDomain);

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
        .read_latency_p50_ns = if (tier.read_latency_p50_ns != 0) tier.read_latency_p50_ns else std.math.maxInt(u64),
        .read_latency_p99_ns = if (tier.read_latency_p99_ns != 0) tier.read_latency_p99_ns else std.math.maxInt(u64),
        .write_latency_p50_ns = if (tier.write_latency_p50_ns != 0) tier.write_latency_p50_ns else std.math.maxInt(u64),
        .write_latency_p99_ns = if (tier.write_latency_p99_ns != 0) tier.write_latency_p99_ns else std.math.maxInt(u64),
        .read_bandwidth_bytes_s = tier.read_bandwidth_bytes_s,
        .write_bandwidth_bytes_s = tier.write_bandwidth_bytes_s,
        .write_cost_nj_per_kib = std.math.maxInt(u64),
        .endurance_cost_ppb_per_kib = std.math.maxInt(u64),
        .volatility_class = std.math.maxInt(u32),
        .failure_domain = std.math.maxInt(u32),
        .max_batch_pages = if (tier.max_batch_pages != 0) tier.max_batch_pages else 1,
        .max_inflight_batches = if (tier.max_inflight_batches != 0) tier.max_inflight_batches else 1,
        .confidentiality_caps = 0,
        .compression_size_classes = 0,
        .compression_leakage_bits_q8 = std.math.maxInt(u16),
        .completion_release_quantum_ns = std.math.maxInt(u64),
        .reserved = @splat(0),
    };
}

pub fn registerTier(io: std.Io, control_fd: i32, provider_fd: i32, tier: config.Tier) !i32 {
    // The kernel transport reaches the tier through an already open device, so
    // it needs no file access of its own. It takes io because the contract
    // does, and a transport that does touch the filesystem must not have to
    // reach around the abstraction the rest of the tree uses.
    _ = io;
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

pub fn admitDomain(io: std.Io, control_fd: i32, cgroup_fd: i32, tier_fds: []const i32, domain: config.Domain) !i32 {
    _ = io;
    if (tier_fds.len == 0 or tier_fds.len > 8) return error.InvalidReservationCount;
    var reservations: [8]TierReservation = undefined;
    for (tier_fds, 0..) |tier_fd, index| reservations[index] = .{
        .tier_fd = tier_fd,
        .capacity_bytes = domain.reserve_capacity_bytes,
        .read_bandwidth_bytes_s = domain.reserve_read_bandwidth_bytes_s,
        .write_bandwidth_bytes_s = domain.reserve_write_bandwidth_bytes_s,
        .queue_slots = domain.reserve_queue_slots,
    };
    var request = AdmitDomain{
        .version = version,
        .size = @sizeOf(AdmitDomain),
        .flags = 0,
        .cgroup_fd = cgroup_fd,
        .domain_fd = -1,
        .fault_service_p99_ns = domain.fault_service_p99_us.? * std.time.ns_per_us,
        .reuse_horizon_us = domain.reuse_horizon_us,
        .reservations_ptr = @intFromPtr(&reservations),
        .reservation_count = @intCast(tier_fds.len),
        .status = 0,
        .stable_cgroup_id = 0,
        .reserved = @splat(0),
    };
    const result = std.os.linux.ioctl(control_fd, admit_ioctl, @intFromPtr(&request));
    if (std.os.linux.errno(result) != .SUCCESS) return error.DomainAdmissionFailed;
    if (request.domain_fd < 0 or request.status != 1) return error.DomainNotAdmitted;
    return request.domain_fd;
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
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(TierReservation));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(AdmitDomain));
    try std.testing.expectEqual(@as(u32, 0xc068bc04), admit_ioctl);
}

test "UUID text maps to stable network-order bytes" {
    const uuid = try parseUuid("018f3f28-7ee0-7dd2-a400-8f847e14c001");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x8f, 0x3f, 0x28 }, uuid[0..4]);
    try std.testing.expectEqual(@as(u8, 0x01), uuid[15]);
}

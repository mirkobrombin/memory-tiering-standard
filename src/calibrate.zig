// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const config = @import("config.zig");
const linux = std.os.linux;

pub const page_bytes = 4096;
pub const chunk_bytes = 1024 * 1024;
pub const max_region_bytes = 64 * 1024 * 1024;
pub const read_samples = 512;
pub const write_samples = 256;

pub const Measurement = struct {
    read_latency_p50_ns: u64,
    read_latency_p99_ns: u64,
    write_latency_p50_ns: u64,
    write_latency_p99_ns: u64,
    read_bandwidth_bytes_s: u64,
    write_bandwidth_bytes_s: u64,
    direct: bool,
};

pub fn percentile(sorted: []const u64, permille: u32) u64 {
    std.debug.assert(sorted.len > 0);
    const rank = (sorted.len * permille + 999) / 1000;
    return sorted[@max(rank, 1) - 1];
}

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn openProvider(path: [:0]const u8, extra: linux.O) !struct { fd: i32, direct: bool } {
    var flags = extra;
    flags.ACCMODE = .RDWR;
    flags.CLOEXEC = true;
    flags.DIRECT = true;
    var result = linux.openat(linux.AT.FDCWD, path, flags, 0);
    if (linux.errno(result) == .INVAL) {
        flags.DIRECT = false;
        result = linux.openat(linux.AT.FDCWD, path, flags, 0);
        if (linux.errno(result) != .SUCCESS) return error.ProviderOpenFailed;
        return .{ .fd = @intCast(result), .direct = false };
    }
    if (linux.errno(result) != .SUCCESS) return error.ProviderOpenFailed;
    return .{ .fd = @intCast(result), .direct = true };
}

fn fileSize(fd: i32) !u64 {
    const end = linux.lseek(fd, 0, linux.SEEK.END);
    if (linux.errno(end) != .SUCCESS) return error.ProviderSizeUnknown;
    return @intCast(end);
}

fn writeAll(fd: i32, buffer: []const u8, offset: u64) !void {
    const result = linux.pwrite(fd, buffer.ptr, buffer.len, @intCast(offset));
    if (linux.errno(result) != .SUCCESS or result != buffer.len) return error.ProviderWriteFailed;
}

fn readAll(fd: i32, buffer: []u8, offset: u64) !void {
    const result = linux.pread(fd, buffer.ptr, buffer.len, @intCast(offset));
    if (linux.errno(result) != .SUCCESS or result != buffer.len) return error.ProviderReadFailed;
}

fn sync(fd: i32) !void {
    if (linux.errno(linux.fdatasync(fd)) != .SUCCESS) return error.ProviderSyncFailed;
}

fn dropCache(fd: i32) !void {
    try sync(fd);
    if (linux.errno(linux.fadvise(fd, 0, 0, linux.POSIX_FADV.DONTNEED)) != .SUCCESS) return error.ProviderCacheDropFailed;
}

fn bandwidth(bytes: u64, elapsed_ns: u64) u64 {
    return @intCast(@as(u128, bytes) * std.time.ns_per_s / @max(elapsed_ns, 1));
}

pub fn measure(allocator: std.mem.Allocator, path: [:0]const u8) !Measurement {
    const opened = try openProvider(path, .{});
    defer _ = linux.close(opened.fd);
    const size = try fileSize(opened.fd);
    const region = @min(size, max_region_bytes) / chunk_bytes * chunk_bytes;
    if (region < chunk_bytes) return error.ProviderTooSmall;

    const buffer = try allocator.alignedAlloc(u8, .fromByteUnits(page_bytes), chunk_bytes);
    defer allocator.free(buffer);
    for (buffer, 0..) |*byte, index| byte.* = @truncate(index *% 131 +% 7);

    var start = now();
    var offset: u64 = 0;
    while (offset < region) : (offset += chunk_bytes) try writeAll(opened.fd, buffer, offset);
    try sync(opened.fd);
    const write_bw = bandwidth(region, now() - start);

    try dropCache(opened.fd);
    start = now();
    offset = 0;
    while (offset < region) : (offset += chunk_bytes) try readAll(opened.fd, buffer, offset);
    const read_bw = bandwidth(region, now() - start);

    try dropCache(opened.fd);

    var prng = std.Random.DefaultPrng.init(now());
    const random = prng.random();
    const pages = region / page_bytes;

    var reads: [read_samples]u64 = undefined;
    for (&reads) |*sample| {
        const at = random.uintLessThan(u64, pages) * page_bytes;
        const begin = now();
        try readAll(opened.fd, buffer[0..page_bytes], at);
        sample.* = now() - begin;
    }

    const synced = try openProvider(path, .{ .DSYNC = true });
    defer _ = linux.close(synced.fd);
    var writes: [write_samples]u64 = undefined;
    for (&writes) |*sample| {
        const at = random.uintLessThan(u64, pages) * page_bytes;
        const begin = now();
        try writeAll(synced.fd, buffer[0..page_bytes], at);
        sample.* = now() - begin;
    }

    std.mem.sort(u64, &reads, {}, std.sort.asc(u64));
    std.mem.sort(u64, &writes, {}, std.sort.asc(u64));
    return .{
        .read_latency_p50_ns = percentile(&reads, 500),
        .read_latency_p99_ns = percentile(&reads, 990),
        .write_latency_p50_ns = percentile(&writes, 500),
        .write_latency_p99_ns = percentile(&writes, 990),
        .read_bandwidth_bytes_s = read_bw,
        .write_bandwidth_bytes_s = write_bw,
        .direct = opened.direct and synced.direct,
    };
}

const measured_keys = [_][]const u8{
    "ReadLatencyP50NSec",
    "ReadLatencyP99NSec",
    "WriteLatencyP50NSec",
    "WriteLatencyP99NSec",
    "ReadBandwidthBytesPerSec",
    "WriteBandwidthBytesPerSec",
};

fn measuredValue(m: Measurement, key_index: usize) u64 {
    return switch (key_index) {
        0 => m.read_latency_p50_ns,
        1 => m.read_latency_p99_ns,
        2 => m.write_latency_p50_ns,
        3 => m.write_latency_p99_ns,
        4 => m.read_bandwidth_bytes_s,
        else => m.write_bandwidth_bytes_s,
    };
}

fn sectionTier(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    const prefix = "[Tier \"";
    if (!std.mem.startsWith(u8, trimmed, prefix) or !std.mem.endsWith(u8, trimmed, "\"]")) return null;
    return trimmed[prefix.len .. trimmed.len - 2];
}

fn lineKey(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    return std.mem.trim(u8, trimmed[0..eq], " \t");
}

pub fn rewrite(allocator: std.mem.Allocator, input: []const u8, tier: []const u8, m: Measurement) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_tier = false;
    var found = false;
    var written = [_]bool{false} ** measured_keys.len;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), "[")) {
            if (in_tier) try appendMissing(allocator, &out, &written, m);
            in_tier = if (sectionTier(line)) |name| std.mem.eql(u8, name, tier) else false;
            if (in_tier) found = true;
        }
        if (!first) try out.append(allocator, '\n');
        first = false;
        if (in_tier) {
            if (lineKey(line)) |key| {
                if (indexOfKey(key)) |index| {
                    try out.print(allocator, "{s}={d}", .{ measured_keys[index], measuredValue(m, index) });
                    written[index] = true;
                    continue;
                }
            }
        }
        try out.appendSlice(allocator, line);
    }
    if (in_tier) try appendMissing(allocator, &out, &written, m);
    if (!found) return error.TierNotFound;
    return out.toOwnedSlice(allocator);
}

fn indexOfKey(key: []const u8) ?usize {
    for (measured_keys, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, key)) return index;
    }
    return null;
}

fn appendMissing(allocator: std.mem.Allocator, out: *std.ArrayList(u8), written: *[measured_keys.len]bool, m: Measurement) !void {
    for (written, 0..) |*done, index| {
        if (done.*) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.print(allocator, "{s}={d}\n", .{ measured_keys[index], measuredValue(m, index) });
        done.* = true;
    }
}

pub fn providerOf(input: []const u8, tier: []const u8) ?[]const u8 {
    var in_tier = false;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), "[")) {
            in_tier = if (sectionTier(line)) |name| std.mem.eql(u8, name, tier) else false;
            continue;
        }
        if (!in_tier) continue;
        const key = lineKey(line) orelse continue;
        if (!std.mem.eql(u8, key, "Provider")) continue;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        return std.mem.trim(u8, trimmed[std.mem.indexOfScalar(u8, trimmed, '=').? + 1 ..], " \t");
    }
    return null;
}

const sample_config =
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
    \\WriteLatencyP50NSec=20000
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
    \\ReserveWriteBandwidthBytesPerSec=50000000
    \\ReserveQueueSlots=4
    \\
;

const sample_measurement = Measurement{
    .read_latency_p50_ns = 310000,
    .read_latency_p99_ns = 2400000,
    .write_latency_p50_ns = 520000,
    .write_latency_p99_ns = 9100000,
    .read_bandwidth_bytes_s = 180000000,
    .write_bandwidth_bytes_s = 90000000,
    .direct = true,
};

test "percentile picks the nearest rank" {
    const values = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(u64, 5), percentile(&values, 500));
    try std.testing.expectEqual(@as(u64, 10), percentile(&values, 990));
    try std.testing.expectEqual(@as(u64, 1), percentile(values[0..1], 990));
}

test "rewrite replaces the measured keys of one tier and keeps the rest" {
    const out = try rewrite(std.testing.allocator, sample_config, "cold", sample_measurement);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ReadLatencyP50NSec=310000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "WriteLatencyP50NSec=520000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ReadLatencyP99NSec=2400000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "WriteBandwidthBytesPerSec=90000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "15000") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FaultServiceP99USec=500") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "ReadLatencyP50NSec="));
    switch (config.parse(out)) {
        .config => |parsed| {
            try std.testing.expectEqual(@as(u64, 310000), parsed.tiers[0].read_latency_p50_ns);
            try std.testing.expectEqual(@as(u64, 9100000), parsed.tiers[0].write_latency_p99_ns);
        },
        .diagnostic => |diag| {
            std.debug.print("line {d}: {s} {s}\n", .{ diag.line, @tagName(diag.reason), diag.key });
            return error.TestUnexpectedResult;
        },
    }
}

test "rewrite refuses an unknown tier" {
    try std.testing.expectError(error.TierNotFound, rewrite(std.testing.allocator, sample_config, "warm", sample_measurement));
}

test "providerOf reads the provider of the named tier" {
    try std.testing.expectEqualStrings("/var/lib/mts/cold.img", providerOf(sample_config, "cold").?);
    try std.testing.expect(providerOf(sample_config, "warm") == null);
}

test "measure reads back a real file" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/cold.img", .{dir.sub_path}, 0);
    defer std.testing.allocator.free(path);
    const created = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(created));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(@intCast(created), 4 * chunk_bytes)));
    _ = linux.close(@intCast(created));
    const m = try measure(std.testing.allocator, path);
    try std.testing.expect(m.read_latency_p50_ns > 0);
    try std.testing.expect(m.read_latency_p99_ns >= m.read_latency_p50_ns);
    try std.testing.expect(m.write_latency_p99_ns >= m.write_latency_p50_ns);
    try std.testing.expect(m.read_bandwidth_bytes_s > 0);
    try std.testing.expect(m.write_bandwidth_bytes_s > 0);
}

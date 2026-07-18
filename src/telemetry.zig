// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub const histogram_bounds_ns = [32]u64{
    1_000,           2_000,           4_000,             8_000,
    16_000,          32_000,          64_000,            128_000,
    256_000,         512_000,         1_000_000,         2_000_000,
    4_000_000,       8_000_000,       16_000_000,        32_000_000,
    64_000_000,      128_000_000,     256_000_000,       512_000_000,
    1_000_000_000,   2_000_000_000,   4_000_000_000,     8_000_000_000,
    16_000_000_000,  32_000_000_000,  64_000_000_000,    128_000_000_000,
    256_000_000_000, 512_000_000_000, 1_000_000_000_000, std.math.maxInt(u64),
};

pub const Histogram = struct {
    buckets: [histogram_bounds_ns.len]u64 = @splat(0),
    sum_ns: u64 = 0,
    samples: u64 = 0,

    pub fn observe(self: *Histogram, latency_ns: u64) void {
        for (histogram_bounds_ns, 0..) |upper, index| {
            if (latency_ns <= upper) {
                self.buckets[index] += 1;
                break;
            }
        }
        self.sum_ns +|= latency_ns;
        self.samples +|= 1;
    }

    pub fn percentileUpper(self: Histogram, numerator: u64, denominator: u64) !u64 {
        if (self.samples == 0 or denominator == 0 or numerator > denominator)
            return error.InvalidPercentile;
        const target = @max(@as(u64, 1), (self.samples * numerator + denominator - 1) / denominator);
        var cumulative: u64 = 0;
        for (self.buckets, histogram_bounds_ns) |count, upper| {
            cumulative += count;
            if (cumulative >= target) return upper;
        }
        unreachable;
    }
};

pub const Counters = struct {
    promotions: u64 = 0,
    demotions: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
    bytes_reconstructed: u64 = 0,
    cpu_copy_bytes: u64 = 0,
    integrity_failures: u64 = 0,
    tlb_flush_batches: u64 = 0,
    shootdown_ipis: u64 = 0,
    coalesced_ranges: u64 = 0,
    pages_flushed: u64 = 0,
    promotion_latency: Histogram = .{},
    demotion_latency: Histogram = .{},
    fault_latency: Histogram = .{},
    queue_delay: Histogram = .{},
    tlb_latency: Histogram = .{},
};

pub const ConfidentialCounters = struct {
    logical_granule_bytes: u64,
    domain: Counters = .{},

    pub fn chargeCompressedWrite(self: *ConfidentialCounters, actual_bytes: u64) void {
        _ = actual_bytes;
        // Physical compression is deliberately not observable through the
        // domain ABI. Capacity and byte counters use the declared granule.
        self.domain.bytes_written +|= self.logical_granule_bytes;
    }
};

test "histogram boundaries are inclusive and percentiles normalized" {
    var histogram = Histogram{};
    histogram.observe(1_000);
    histogram.observe(1_001);
    histogram.observe(1_000_000);
    try std.testing.expectEqual(@as(u64, 1), histogram.buckets[0]);
    try std.testing.expectEqual(@as(u64, 1), histogram.buckets[1]);
    try std.testing.expectEqual(@as(u64, 1_000_000), try histogram.percentileUpper(99, 100));
}

test "confidential compression exposes only fixed logical charges" {
    var small = ConfidentialCounters{ .logical_granule_bytes = 4096 };
    var large = ConfidentialCounters{ .logical_granule_bytes = 4096 };
    small.chargeCompressedWrite(12);
    large.chargeCompressedWrite(3_800);
    try std.testing.expectEqual(small.domain.bytes_written, large.domain.bytes_written);
}

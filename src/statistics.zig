// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub const bootstrap_samples = 10_000;

pub const Interval = struct {
    estimate: f64,
    lower: f64,
    upper: f64,
};

const SplitMix64 = struct {
    state: u64,

    fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var value = self.state;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        return value ^ (value >> 31);
    }

    fn index(self: *SplitMix64, bound: usize) usize {
        return @intCast(self.next() % bound);
    }
};

fn average(values: []const f64) !f64 {
    if (values.len == 0) return error.EmptySample;
    var sum: f64 = 0;
    for (values) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteSample;
        sum += value;
    }
    return sum / @as(f64, @floatFromInt(values.len));
}

fn interval(samples: []f64, estimate: f64) Interval {
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    const lower_index = (samples.len * 25) / 1000;
    const upper_index = @min(samples.len - 1, (samples.len * 975) / 1000);
    return .{
        .estimate = estimate,
        .lower = samples[lower_index],
        .upper = samples[upper_index],
    };
}

pub fn pairedRatio(
    allocator: std.mem.Allocator,
    numerator: []const f64,
    denominator: []const f64,
    seed: u64,
) !Interval {
    if (numerator.len != denominator.len or numerator.len < 2)
        return error.InvalidPairedSample;
    const numerator_mean = try average(numerator);
    const denominator_mean = try average(denominator);
    if (numerator_mean < 0 or denominator_mean <= 0) return error.InvalidRatio;

    const samples = try allocator.alloc(f64, bootstrap_samples);
    defer allocator.free(samples);
    var random = SplitMix64{ .state = seed };
    for (samples) |*sample| {
        var numerator_sum: f64 = 0;
        var denominator_sum: f64 = 0;
        for (0..numerator.len) |_| {
            const selected = random.index(numerator.len);
            numerator_sum += numerator[selected];
            denominator_sum += denominator[selected];
        }
        if (denominator_sum <= 0) return error.InvalidRatio;
        sample.* = numerator_sum / denominator_sum;
    }
    return interval(samples, numerator_mean / denominator_mean);
}

pub fn meanInterval(
    allocator: std.mem.Allocator,
    values: []const f64,
    seed: u64,
) !Interval {
    if (values.len < 2) return error.InvalidSample;
    const estimate = try average(values);
    const samples = try allocator.alloc(f64, bootstrap_samples);
    defer allocator.free(samples);
    var random = SplitMix64{ .state = seed };
    for (samples) |*sample| {
        var sum: f64 = 0;
        for (0..values.len) |_| sum += values[random.index(values.len)];
        sample.* = sum / @as(f64, @floatFromInt(values.len));
    }
    return interval(samples, estimate);
}

test "paired bootstrap preserves an exact ratio" {
    const numerator = [_]f64{ 99.6, 199.2, 298.8, 398.4, 498.0 };
    const denominator = [_]f64{ 100, 200, 300, 400, 500 };
    const result = try pairedRatio(std.testing.allocator, &numerator, &denominator, 7);
    try std.testing.expectApproxEqAbs(0.996, result.estimate, 0.000001);
    try std.testing.expectApproxEqAbs(0.996, result.lower, 0.000001);
    try std.testing.expectApproxEqAbs(0.996, result.upper, 0.000001);
}

test "mean interval is deterministic" {
    const values = [_]f64{ 0.10, 0.20, 0.30, 0.40, 0.50 };
    const first = try meanInterval(std.testing.allocator, &values, 0x4d54533032);
    const second = try meanInterval(std.testing.allocator, &values, 0x4d54533032);
    try std.testing.expectEqual(first, second);
    try std.testing.expect(first.lower <= first.estimate);
    try std.testing.expect(first.upper >= first.estimate);
}

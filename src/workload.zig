// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub const Kind = enum { redis_zipf, jvm_graph, torch_train };

const SplitMix64 = struct {
    state: u64,

    fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var value = self.state;
        value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
        value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
        return value ^ (value >> 31);
    }

    fn unit(self: *SplitMix64) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) / 9_007_199_254_740_992.0;
    }
};

pub const Generator = struct {
    allocator: std.mem.Allocator,
    kind: Kind,
    keys: u64,
    random: SplitMix64,
    cdf: ?[]f64,
    event: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, kind: Kind, keys: u64, seed: u64) !Generator {
        if (keys == 0 or keys > 100_000_000) return error.InvalidKeyCount;
        var generator = Generator{
            .allocator = allocator,
            .kind = kind,
            .keys = keys,
            .random = .{ .state = seed },
            .cdf = null,
        };
        if (kind != .torch_train) {
            const exponent: f64 = if (kind == .redis_zipf) 0.99 else 0.90;
            const cdf = try allocator.alloc(f64, @intCast(keys));
            errdefer allocator.free(cdf);
            var sum: f64 = 0;
            for (cdf, 0..) |*entry, index| {
                sum += std.math.pow(f64, @floatFromInt(index + 1), -exponent);
                entry.* = sum;
            }
            for (cdf) |*entry| entry.* /= sum;
            generator.cdf = cdf;
        }
        return generator;
    }

    pub fn deinit(self: *Generator) void {
        if (self.cdf) |cdf| self.allocator.free(cdf);
    }

    pub fn next(self: *Generator) u64 {
        defer self.event += 1;
        if (self.kind == .torch_train) {
            // Four microbatches revisit the same phased working set before
            // the declared optimizer barrier advances to the next phase.
            const microbatch = self.event % 4;
            const position = self.event / 4;
            return (position + microbatch *% (self.keys / 4 + 1)) % self.keys;
        }
        const cdf = self.cdf.?;
        const sample = self.random.unit();
        var low: usize = 0;
        var high: usize = cdf.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (cdf[middle] < sample) low = middle + 1 else high = middle;
        }
        return @min(low, cdf.len - 1);
    }
};

test "Zipf replay is deterministic and favors the head" {
    var first = try Generator.init(std.testing.allocator, .redis_zipf, 100, 7);
    defer first.deinit();
    var second = try Generator.init(std.testing.allocator, .redis_zipf, 100, 7);
    defer second.deinit();
    var head: usize = 0;
    var tail: usize = 0;
    for (0..10_000) |_| {
        const a = first.next();
        try std.testing.expectEqual(a, second.next());
        if (a < 10) head += 1;
        if (a >= 90) tail += 1;
    }
    try std.testing.expect(head > tail * 5);
}

test "torch replay declares four distinct microbatch phases" {
    var generator = try Generator.init(std.testing.allocator, .torch_train, 64, 0);
    defer generator.deinit();
    try std.testing.expectEqual(@as(u64, 0), generator.next());
    try std.testing.expectEqual(@as(u64, 17), generator.next());
    try std.testing.expectEqual(@as(u64, 34), generator.next());
    try std.testing.expectEqual(@as(u64, 51), generator.next());
}

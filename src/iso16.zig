// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub const bucket_count = 16;
pub const q12_max: u16 = 4095;

pub const Telemetry = struct {
    labeled_samples: u64 = 0,
    brier_sum: f64 = 0,
    positive_labels: u64 = 0,

    pub fn brier(self: Telemetry) ?f64 {
        if (self.labeled_samples == 0) return null;
        return self.brier_sum / @as(f64, @floatFromInt(self.labeled_samples));
    }

    pub fn baseBrier(self: Telemetry) ?f64 {
        if (self.labeled_samples == 0) return null;
        const rate = @as(f64, @floatFromInt(self.positive_labels)) /
            @as(f64, @floatFromInt(self.labeled_samples));
        return rate * (1.0 - rate);
    }

    pub fn skill(self: Telemetry) ?f64 {
        const actual = self.brier() orelse return null;
        const base = self.baseBrier() orelse return null;
        if (base == 0) return null;
        return 1.0 - actual / base;
    }
};

pub const Predictor = struct {
    // Bucket zero is youngest, so calibrated probabilities never increase with age.
    positive: [bucket_count]f64 = @splat(1.0),
    total: [bucket_count]f64 = @splat(2.0),
    probability: [bucket_count]f64 = @splat(0.5),
    telemetry: Telemetry = .{},
    decay: f64 = 1.0,

    pub fn init(decay: f64) Predictor {
        return .{ .decay = std.math.clamp(decay, 0.0, 1.0) };
    }

    pub fn bucket(access_age_epochs: u8) u4 {
        return @intCast(@min(access_age_epochs, 15));
    }

    pub fn predict(self: Predictor, access_age_epochs: u8) f64 {
        return self.probability[bucket(access_age_epochs)];
    }

    pub fn predictQ12(self: Predictor, access_age_epochs: u8) u16 {
        return @intFromFloat(@round(self.predict(access_age_epochs) * q12_max));
    }

    pub fn observe(self: *Predictor, access_age_epochs: u8, reused: bool) void {
        const g = bucket(access_age_epochs);
        const p = self.probability[g];
        const y: f64 = if (reused) 1.0 else 0.0;
        const error_value = p - y;
        self.telemetry.brier_sum += error_value * error_value;
        self.telemetry.labeled_samples += 1;
        if (reused) self.telemetry.positive_labels += 1;

        self.total[g] = self.total[g] * self.decay + 1.0;
        self.positive[g] = self.positive[g] * self.decay + y;
    }

    pub fn calibrate(self: *Predictor) void {
        var mean: [bucket_count]f64 = undefined;
        var weight: [bucket_count]f64 = undefined;
        var first: [bucket_count]u8 = undefined;
        var last: [bucket_count]u8 = undefined;
        var blocks: usize = 0;

        for (0..bucket_count) |g| {
            mean[blocks] = self.positive[g] / self.total[g];
            weight[blocks] = self.total[g];
            first[blocks] = @intCast(g);
            last[blocks] = @intCast(g);
            blocks += 1;

            // PAV merges an inversion. ISO16 requires p(young) >= p(old).
            while (blocks >= 2 and mean[blocks - 2] < mean[blocks - 1]) {
                const left = blocks - 2;
                const right = blocks - 1;
                const combined = weight[left] + weight[right];
                mean[left] = (mean[left] * weight[left] + mean[right] * weight[right]) / combined;
                weight[left] = combined;
                last[left] = last[right];
                blocks -= 1;
            }
        }

        for (0..blocks) |block| {
            var g: usize = first[block];
            while (g <= last[block]) : (g += 1) self.probability[g] = mean[block];
        }
    }
};

test "isotonic calibration merges age inversions" {
    var predictor = Predictor.init(1.0);
    predictor.positive[0] = 2;
    predictor.total[0] = 10;
    predictor.positive[1] = 8;
    predictor.total[1] = 10;
    predictor.calibrate();

    try std.testing.expectApproxEqAbs(0.5, predictor.probability[0], 0.0001);
    try std.testing.expectApproxEqAbs(0.5, predictor.probability[1], 0.0001);
    for (1..bucket_count) |g| {
        try std.testing.expect(predictor.probability[g - 1] >= predictor.probability[g]);
    }
}

test "Brier skill is positive for a useful predictor" {
    var predictor = Predictor.init(1.0);
    predictor.probability[0] = 0.9;
    predictor.probability[15] = 0.1;
    for (0..100) |_| {
        predictor.observe(0, true);
        predictor.observe(15, false);
    }
    try std.testing.expect((predictor.telemetry.skill() orelse -1) > 0);
}

test "Q12 spans the complete normative range" {
    var predictor = Predictor.init(1.0);
    predictor.probability[0] = 1.0;
    predictor.probability[15] = 0.0;
    try std.testing.expectEqual(q12_max, predictor.predictQ12(0));
    try std.testing.expectEqual(@as(u16, 0), predictor.predictQ12(255));
}

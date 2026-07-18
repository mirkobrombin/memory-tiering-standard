// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub const Inputs = struct {
    compute_seconds: f64,
    read_bytes: f64,
    write_bytes: f64,
    io_count: f64,
    read_bandwidth_bytes_s: f64,
    write_bandwidth_bytes_s: f64,
    recover_p50_seconds: f64,
    qd_max: f64,
    critical_seconds: f64,
    completed_work_units: f64,
};

pub const Result = struct {
    floor_seconds: f64,
    oracle_throughput: f64,

    pub fn threshold(self: Result, full_ram_throughput: f64) f64 {
        return @min(0.95 * full_ram_throughput, 0.97 * self.oracle_throughput);
    }
};

pub fn calculate(input: Inputs) !Result {
    if (input.compute_seconds < 0 or input.read_bytes < 0 or input.write_bytes < 0 or
        input.io_count < 0 or input.critical_seconds < 0 or input.completed_work_units <= 0)
        return error.InvalidInput;
    if (input.read_bandwidth_bytes_s <= 0 or input.write_bandwidth_bytes_s <= 0 or
        input.recover_p50_seconds < 0 or input.qd_max < 1)
        return error.InvalidServiceCurve;

    const read_seconds = input.read_bytes / input.read_bandwidth_bytes_s;
    const write_seconds = input.write_bytes / input.write_bandwidth_bytes_s;
    const queue_seconds = input.io_count * input.recover_p50_seconds / input.qd_max;
    const floor = @max(input.compute_seconds, @max(read_seconds, @max(write_seconds, @max(queue_seconds, input.critical_seconds))));
    if (floor <= 0) return error.ZeroTimeFloor;
    return .{
        .floor_seconds = floor,
        .oracle_throughput = input.completed_work_units / floor,
    };
}

test "NVMe bandwidth can control the optimistic floor" {
    const result = try calculate(.{
        .compute_seconds = 1,
        .read_bytes = 35_000_000_000,
        .write_bytes = 0,
        .io_count = 1,
        .read_bandwidth_bytes_s = 7_000_000_000,
        .write_bandwidth_bytes_s = 7_000_000_000,
        .recover_p50_seconds = 0.0001,
        .qd_max = 64,
        .critical_seconds = 0,
        .completed_work_units = 100,
    });
    try std.testing.expectApproxEqAbs(5.0, result.floor_seconds, 0.0001);
    try std.testing.expectApproxEqAbs(20.0, result.oracle_throughput, 0.0001);
    try std.testing.expectApproxEqAbs(19.4, result.threshold(100), 0.0001);
}

test "the gate never asks for more than 95 percent of full RAM" {
    const result = Result{ .floor_seconds = 1, .oracle_throughput = 1000 };
    try std.testing.expectApproxEqAbs(95.0, result.threshold(100), 0.0001);
}

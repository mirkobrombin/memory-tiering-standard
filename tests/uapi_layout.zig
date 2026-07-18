// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

const Shift = struct {
    version: u6 = 0,
    state: u6 = 4,
    reuse: u6 = 8,
    rebuild: u6 = 20,
    current: u6 = 32,
    target: u6 = 40,
    policy: u6 = 48,
    age: u6 = 56,
};

fn put(value: u64, shift: u6, bits: u6) u64 {
    const mask = (@as(u64, 1) << bits) - 1;
    return (value & mask) << shift;
}

test "descriptor v2 consumes exactly one word without overlap" {
    const shift = Shift{};
    const word = put(2, shift.version, 4) |
        put(6, shift.state, 4) |
        put(4095, shift.reuse, 12) |
        put(4095, shift.rebuild, 12) |
        put(254, shift.current, 8) |
        put(255, shift.target, 8) |
        put(255, shift.policy, 8) |
        put(255, shift.age, 8);
    try std.testing.expectEqual(@as(u64, 0xffff_fffe_ffff_ff62), word);
}

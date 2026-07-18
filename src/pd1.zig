// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub const Resources = struct {
    capacity: f64 = 0,
    read_bandwidth: f64 = 0,
    write_bandwidth: f64 = 0,
    queue_slots: f64 = 0,

    fn add(left: Resources, right: Resources) Resources {
        return .{
            .capacity = left.capacity + right.capacity,
            .read_bandwidth = left.read_bandwidth + right.read_bandwidth,
            .write_bandwidth = left.write_bandwidth + right.write_bandwidth,
            .queue_slots = left.queue_slots + right.queue_slots,
        };
    }

    fn subtract(left: Resources, right: Resources) Resources {
        return .{
            .capacity = left.capacity - right.capacity,
            .read_bandwidth = left.read_bandwidth - right.read_bandwidth,
            .write_bandwidth = left.write_bandwidth - right.write_bandwidth,
            .queue_slots = left.queue_slots - right.queue_slots,
        };
    }

    fn fits(demand: Resources, available: Resources) bool {
        return demand.capacity <= available.capacity and
            demand.read_bandwidth <= available.read_bandwidth and
            demand.write_bandwidth <= available.write_bandwidth and
            demand.queue_slots <= available.queue_slots;
    }
};

pub const Reservation = struct {
    domain_id: u64,
    resources: Resources,
};

pub fn Admission(comptime max_domains: usize) type {
    return struct {
        const Self = @This();
        usable: Resources,
        reserved: Resources = .{},
        reservations: [max_domains]Reservation = undefined,
        count: usize = 0,

        pub fn init(usable: Resources) Self {
            return .{ .usable = usable };
        }

        pub fn admit(self: *Self, domain_id: u64, upper_confidence: Resources) !void {
            for (self.reservations[0..self.count]) |reservation| {
                if (reservation.domain_id == domain_id) return error.AlreadyAdmitted;
            }
            if (self.count == max_domains) return error.AdmissionTableFull;
            const with_headroom = Resources{
                .capacity = upper_confidence.capacity * 1.2,
                .read_bandwidth = upper_confidence.read_bandwidth * 1.2,
                .write_bandwidth = upper_confidence.write_bandwidth * 1.2,
                .queue_slots = @ceil(upper_confidence.queue_slots * 1.2),
            };
            const available = self.usable.subtract(self.reserved);
            if (!with_headroom.fits(available)) return error.AdmissionDenied;
            self.reservations[self.count] = .{
                .domain_id = domain_id,
                .resources = with_headroom,
            };
            self.count += 1;
            self.reserved = self.reserved.add(with_headroom);
        }

        pub fn release(self: *Self, domain_id: u64) !void {
            for (self.reservations[0..self.count], 0..) |reservation, index| {
                if (reservation.domain_id != domain_id) continue;
                self.reserved = self.reserved.subtract(reservation.resources);
                self.count -= 1;
                self.reservations[index] = self.reservations[self.count];
                return;
            }
            return error.NotAdmitted;
        }
    };
}

pub const Prices = struct {
    capacity: f64 = 0,
    read_bandwidth: f64 = 0,
    write_bandwidth: f64 = 0,
    queue_slots: f64 = 0,

    pub fn update(
        self: *Prices,
        demand: Resources,
        usable: Resources,
        service_p99: Resources,
        has_reservations: bool,
    ) !void {
        if (usable.capacity <= 0 or usable.read_bandwidth <= 0 or
            usable.write_bandwidth <= 0 or usable.queue_slots <= 0)
            return error.InvalidUsableResources;
        const target: f64 = if (has_reservations) 0.8 else 0.9;
        self.capacity = ascend(self.capacity, demand.capacity, usable.capacity, service_p99.capacity, target);
        self.read_bandwidth = ascend(self.read_bandwidth, demand.read_bandwidth, usable.read_bandwidth, service_p99.read_bandwidth, target);
        self.write_bandwidth = ascend(self.write_bandwidth, demand.write_bandwidth, usable.write_bandwidth, service_p99.write_bandwidth, target);
        self.queue_slots = ascend(self.queue_slots, demand.queue_slots, usable.queue_slots, service_p99.queue_slots, target);
    }

    fn ascend(lambda: f64, demand: f64, usable: f64, p99: f64, target: f64) f64 {
        const eta = p99 / (8.0 * usable);
        return @max(0.0, lambda + eta * (demand - target * usable));
    }
};

pub const PageCost = struct {
    reuse_probability: f64,
    recover_cost: f64,
    rebuild_cost: f64,
    transfer_cost: f64,
    mmu_unmap_cost: f64,
    tlb_shootdown_cost: f64,
    write_cost: f64,
    charged_bytes: f64,
    expected_read_bytes: f64,
    expected_write_bytes: f64,
    queue_slots: f64,
    slo_risk_penalty: f64,

    pub fn value(self: PageCost, prices: Prices) f64 {
        return self.reuse_probability * @min(self.recover_cost, self.rebuild_cost) +
            self.transfer_cost + self.mmu_unmap_cost + self.tlb_shootdown_cost +
            self.write_cost + prices.capacity * self.charged_bytes +
            prices.read_bandwidth * self.expected_read_bytes +
            prices.write_bandwidth * self.expected_write_bytes +
            prices.queue_slots * self.queue_slots + self.slo_risk_penalty;
    }
};

pub const Hysteresis = struct {
    candidate_tier: u8 = 0xff,
    consecutive_epochs: u8 = 0,
    entered_tier_ns: u64,

    pub fn eligible(
        self: *Hysteresis,
        candidate_tier: u8,
        now_ns: u64,
        reuse_horizon_ns: u64,
        control_epoch_ns: u64,
        migration_p99_ns: u64,
        current_cost: f64,
        candidate_cost: f64,
        predicted_migration_cost: f64,
        has_tokens: bool,
    ) bool {
        if (candidate_tier != self.candidate_tier) {
            self.candidate_tier = candidate_tier;
            self.consecutive_epochs = 1;
        } else if (self.consecutive_epochs < std.math.maxInt(u8)) {
            self.consecutive_epochs += 1;
        }
        const dwell = @max(reuse_horizon_ns / 4, @max(4 * control_epoch_ns, 2 * migration_p99_ns));
        const benefit = current_cost - candidate_cost;
        return self.consecutive_epochs >= 3 and now_ns -| self.entered_tier_ns >= dwell and
            benefit >= @max(current_cost / 8.0, predicted_migration_cost) and has_tokens;
    }
};

pub const Fault = struct {
    timestamp_ns: u64,
    slo_target_ns: u64,
    cgroup_id: u64,
    sequence: u64,

    pub fn deadline(self: Fault) u64 {
        return self.timestamp_ns +| self.slo_target_ns;
    }

    pub fn lessThan(_: void, left: Fault, right: Fault) bool {
        if (left.deadline() != right.deadline()) return left.deadline() < right.deadline();
        if (left.timestamp_ns != right.timestamp_ns) return left.timestamp_ns < right.timestamp_ns;
        if (left.cgroup_id != right.cgroup_id) return left.cgroup_id < right.cgroup_id;
        return left.sequence < right.sequence;
    }
};

test "admission headroom makes reservations non-overcommitting" {
    var admission = Admission(4).init(.{
        .capacity = 120,
        .read_bandwidth = 120,
        .write_bandwidth = 120,
        .queue_slots = 12,
    });
    const request = Resources{ .capacity = 50, .read_bandwidth = 50, .write_bandwidth = 50, .queue_slots = 5 };
    try admission.admit(1, request);
    try admission.admit(2, request);
    try std.testing.expectError(error.AdmissionDenied, admission.admit(3, request));
    try admission.release(1);
    try admission.admit(3, request);
}

test "dual prices rise only beyond the reservation target" {
    var prices = Prices{};
    const usable = Resources{ .capacity = 100, .read_bandwidth = 100, .write_bandwidth = 100, .queue_slots = 100 };
    const service = Resources{ .capacity = 8, .read_bandwidth = 8, .write_bandwidth = 8, .queue_slots = 8 };
    try prices.update(.{ .capacity = 90, .read_bandwidth = 70, .write_bandwidth = 80, .queue_slots = 100 }, usable, service, true);
    try std.testing.expect(prices.capacity > 0);
    try std.testing.expectEqual(@as(f64, 0), prices.read_bandwidth);
    try std.testing.expect(prices.queue_slots > 0);
}

test "hysteresis requires three epochs dwell benefit and tokens" {
    var state = Hysteresis{ .entered_tier_ns = 0 };
    try std.testing.expect(!state.eligible(2, 4_000, 4_000, 500, 200, 100, 80, 10, true));
    try std.testing.expect(!state.eligible(2, 4_500, 4_000, 500, 200, 100, 80, 10, true));
    try std.testing.expect(state.eligible(2, 5_000, 4_000, 500, 200, 100, 80, 10, true));
}

test "EDF tie break is deterministic and never spends tail budget" {
    var faults = [_]Fault{
        .{ .timestamp_ns = 100, .slo_target_ns = 200, .cgroup_id = 2, .sequence = 1 },
        .{ .timestamp_ns = 100, .slo_target_ns = 200, .cgroup_id = 1, .sequence = 2 },
        .{ .timestamp_ns = 50, .slo_target_ns = 100, .cgroup_id = 9, .sequence = 1 },
    };
    std.mem.sort(Fault, &faults, {}, Fault.lessThan);
    try std.testing.expectEqual(@as(u64, 150), faults[0].deadline());
    try std.testing.expectEqual(@as(u64, 1), faults[1].cgroup_id);
    try std.testing.expectEqual(@as(u64, 2), faults[2].cgroup_id);
}

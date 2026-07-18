// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const objects = @import("object_table.zig");
const telemetry = @import("telemetry.zig");

pub const Operation = enum(u8) { promote, demote, free };
pub const TierState = enum(u8) { active, draining, failed };
pub const DomainState = enum(u8) { admitted, at_risk, violated };

pub const Request = struct {
    page_id: u64,
    payload_tag: u64,
    object: ?objects.ObjectId = null,
    bytes: u32 = 4096,
};

pub const Completion = struct {
    batch_id: u64,
    page_id: u64,
    operation: Operation,
    object: ?objects.ObjectId,
    status: Status,
    bytes_moved: u32,
    cpu_copy_bytes: u32,
    submit_ns: u64,
    complete_ns: u64,

    pub const Status = enum(u8) { ok, stale, integrity, provider_lost, cancelled };
};

pub const ReclaimNotice = struct {
    page_id: u64,
    batch_id: u64,
    deadline_ns: u64,
    proposed_tier: u16,
};

pub fn Ring(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        entries: [capacity]T = undefined,
        head: usize = 0,
        len: usize = 0,

        pub fn push(self: *Self, value: T) !void {
            if (self.len == capacity) return error.RingFull;
            self.entries[(self.head + self.len) % capacity] = value;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const value = self.entries[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return value;
        }
    };
}

pub const Mapping = struct {
    mm_id: u64,
    numa_node: u16,
    address: u64,
    page_size: u32 = 4096,
    cpus: u16,
};

pub const TlbPlan = struct {
    ranges: u32 = 0,
    pages: u32 = 0,
    ipis: u32 = 0,

    pub fn build(sorted: []const Mapping) !TlbPlan {
        var plan = TlbPlan{};
        var previous: ?Mapping = null;
        for (sorted) |mapping| {
            if (previous) |last| {
                const ordered = mapping.mm_id > last.mm_id or
                    (mapping.mm_id == last.mm_id and (mapping.numa_node > last.numa_node or
                        (mapping.numa_node == last.numa_node and mapping.address >= last.address)));
                if (!ordered) return error.UnsortedMappings;
                const contiguous = mapping.mm_id == last.mm_id and
                    mapping.numa_node == last.numa_node and
                    mapping.address == last.address + last.page_size;
                if (!contiguous) {
                    plan.ranges += 1;
                    plan.ipis += last.cpus;
                }
            } else {
                plan.ranges = 1;
            }
            plan.pages += 1;
            previous = mapping;
        }
        if (previous) |last| plan.ipis += last.cpus;
        return plan;
    }
};

pub fn Engine(comptime object_capacity: usize, comptime ring_capacity: usize) type {
    return struct {
        const Self = @This();
        table: objects.Table(object_capacity) = .{},
        completions: Ring(Completion, ring_capacity) = .{},
        notices: Ring(ReclaimNotice, ring_capacity) = .{},
        counters: telemetry.Counters = .{},
        tier_state: TierState = .active,
        domain_state: DomainState = .admitted,
        next_batch_id: u64 = 1,

        pub fn preReclaim(self: *Self, page_id: u64, deadline_ns: u64, tier: u16) !u64 {
            const batch_id = self.next_batch_id;
            self.next_batch_id += 1;
            try self.notices.push(.{
                .page_id = page_id,
                .batch_id = batch_id,
                .deadline_ns = deadline_ns,
                .proposed_tier = tier,
            });
            return batch_id;
        }

        pub fn submit(self: *Self, operation: Operation, requests: []const Request, now_ns: u64) !u64 {
            if (requests.len == 0 or requests.len > ring_capacity) return error.InvalidBatch;
            if (self.tier_state != .active and operation == .demote) return error.TierDraining;
            if (self.completions.len + requests.len > ring_capacity) return error.RingFull;

            const batch_id = self.next_batch_id;
            self.next_batch_id += 1;
            for (requests) |request| {
                var completion = Completion{
                    .batch_id = batch_id,
                    .page_id = request.page_id,
                    .operation = operation,
                    .object = request.object,
                    .status = .ok,
                    .bytes_moved = request.bytes,
                    .cpu_copy_bytes = 0,
                    .submit_ns = now_ns,
                    .complete_ns = now_ns,
                };
                switch (operation) {
                    .demote => {
                        completion.object = self.table.allocate(request.payload_tag) catch blk: {
                            completion.status = .provider_lost;
                            completion.bytes_moved = 0;
                            break :blk null;
                        };
                        self.counters.demotions +|= 1;
                        self.counters.bytes_written +|= completion.bytes_moved;
                    },
                    .promote => {
                        if (request.object) |id| {
                            self.table.cacheFill(id, request.payload_tag) catch |err| switch (err) {
                                error.IntegrityFailure => {
                                    completion.status = .integrity;
                                    self.counters.integrity_failures +|= 1;
                                },
                                else => completion.status = .stale,
                            };
                        } else completion.status = .stale;
                        self.counters.promotions +|= 1;
                        self.counters.bytes_read +|= completion.bytes_moved;
                    },
                    .free => {
                        if (request.object) |id| self.table.release(id) catch {
                            completion.status = .stale;
                        } else completion.status = .stale;
                        completion.bytes_moved = 0;
                    },
                }
                try self.completions.push(completion);
            }
            return batch_id;
        }

        pub fn providerLost(self: *Self) void {
            self.tier_state = .draining;
            // Provider loss invalidates the admission proof atomically. The
            // caller emits mts:slo_transition with FD_CLOSED as its cause.
            if (self.domain_state == .admitted) self.domain_state = .at_risk;
        }
    };
}

test "batch completion preserves object identity without CPU copies" {
    var engine = Engine(4, 8){};
    const request = [_]Request{.{ .page_id = 9, .payload_tag = 0x1234 }};
    const batch = try engine.submit(.demote, &request, 100);
    const put = engine.completions.pop().?;
    try std.testing.expectEqual(batch, put.batch_id);
    try std.testing.expectEqual(@as(u32, 0), put.cpu_copy_bytes);

    const get_request = [_]Request{.{
        .page_id = 9,
        .payload_tag = 0x1234,
        .object = put.object,
    }};
    _ = try engine.submit(.promote, &get_request, 200);
    const get = engine.completions.pop().?;
    try std.testing.expectEqual(Completion.Status.ok, get.status);
}

test "provider loss rejects demotion and marks admitted domains at risk" {
    var engine = Engine(1, 2){};
    engine.providerLost();
    try std.testing.expectEqual(TierState.draining, engine.tier_state);
    try std.testing.expectEqual(DomainState.at_risk, engine.domain_state);
    const request = [_]Request{.{ .page_id = 1, .payload_tag = 1 }};
    try std.testing.expectError(error.TierDraining, engine.submit(.demote, &request, 0));
}

test "TLB plan coalesces only contiguous mappings in one mm and node" {
    const mappings = [_]Mapping{
        .{ .mm_id = 1, .numa_node = 0, .address = 0x1000, .cpus = 8 },
        .{ .mm_id = 1, .numa_node = 0, .address = 0x2000, .cpus = 8 },
        .{ .mm_id = 1, .numa_node = 1, .address = 0x3000, .cpus = 4 },
        .{ .mm_id = 2, .numa_node = 0, .address = 0x1000, .cpus = 2 },
    };
    const plan = try TlbPlan.build(&mappings);
    try std.testing.expectEqual(@as(u32, 3), plan.ranges);
    try std.testing.expectEqual(@as(u32, 4), plan.pages);
    try std.testing.expectEqual(@as(u32, 14), plan.ipis);
}

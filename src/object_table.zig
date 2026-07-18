// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub const refcount_freeze: u32 = 0x00ff_fffe;
pub const invalid_refcount: u32 = 0x00ff_ffff;

pub const Flag = enum(u8) {
    frozen = 1 << 0,
    cache_present = 1 << 1,
    cache_validated = 1 << 2,
    retired = 1 << 3,
};

pub const ObjectId = struct {
    slot: u32,
    generation: u32,
};

pub const ForkResult = union(enum) {
    shared: ObjectId,
    clone_required: ObjectId,
};

pub const Slot = struct {
    refcount: u32 = 0,
    generation: u32 = 0,
    flags: u8 = 0,
    payload_tag: u64 = 0,
    writes: u64 = 0,

    pub fn packedOwner(self: Slot) u64 {
        return @as(u64, self.refcount) |
            (@as(u64, self.generation) << 24) |
            (@as(u64, self.flags) << 56);
    }

    fn has(self: Slot, flag: Flag) bool {
        return self.flags & @intFromEnum(flag) != 0;
    }

    fn set(self: *Slot, flag: Flag) void {
        self.flags |= @intFromEnum(flag);
    }

    fn clear(self: *Slot, flag: Flag) void {
        self.flags &= ~@intFromEnum(flag);
    }
};

pub fn Table(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        slots: [capacity]Slot = @splat(.{}),

        pub fn allocate(self: *Self, payload_tag: u64) !ObjectId {
            for (&self.slots, 0..) |*slot, index| {
                if (slot.refcount != 0 or slot.has(.retired)) continue;
                if (slot.generation == std.math.maxInt(u32)) {
                    slot.set(.retired);
                    continue;
                }
                slot.generation += 1;
                slot.refcount = 1;
                slot.flags = 0;
                slot.payload_tag = payload_tag;
                slot.writes += 1;
                return .{ .slot = @intCast(index), .generation = slot.generation };
            }
            return error.ObjectTableFull;
        }

        fn resolve(self: *Self, id: ObjectId) !*Slot {
            if (id.slot >= capacity) return error.InvalidObject;
            const slot = &self.slots[id.slot];
            if (slot.refcount == 0 or slot.generation != id.generation)
                return error.StaleObject;
            return slot;
        }

        pub fn forkReference(self: *Self, id: ObjectId) !ForkResult {
            const slot = try self.resolve(id);
            if (slot.has(.frozen) or slot.refcount == refcount_freeze) {
                slot.set(.frozen);
                return .{ .clone_required = id };
            }
            slot.refcount += 1;
            if (slot.refcount == refcount_freeze) slot.set(.frozen);
            return .{ .shared = id };
        }

        pub fn release(self: *Self, id: ObjectId) !void {
            const slot = try self.resolve(id);
            slot.refcount -= 1;
            if (slot.refcount != 0) return;
            slot.flags = 0;
            slot.payload_tag = 0;
        }

        pub fn cacheFill(self: *Self, id: ObjectId, payload_tag: u64) !void {
            const slot = try self.resolve(id);
            if (slot.payload_tag != payload_tag) return error.IntegrityFailure;
            slot.set(.cache_present);
            slot.set(.cache_validated);
        }

        pub fn cacheDiscard(self: *Self, id: ObjectId) !void {
            const slot = try self.resolve(id);
            slot.clear(.cache_present);
            slot.clear(.cache_validated);
        }

        pub fn reclaimCached(self: *Self, id: ObjectId) !void {
            // The authoritative payload already exists. Reclaim only drops the
            // cache folio and must never spend another provider write.
            try self.cacheDiscard(id);
        }

        pub fn copyOnWrite(self: *Self, id: ObjectId, new_payload_tag: u64) !ObjectId {
            const slot = try self.resolve(id);
            if (slot.refcount == 1) {
                slot.payload_tag = new_payload_tag;
                slot.writes += 1;
                slot.clear(.cache_validated);
                return id;
            }
            try self.release(id);
            return self.allocate(new_payload_tag);
        }

        pub fn get(self: *Self, id: ObjectId) !Slot {
            return (try self.resolve(id)).*;
        }
    };
}

test "fork shares an object and COW writes a distinct generation" {
    var table = Table(4){};
    const original = try table.allocate(0x1111);
    const forked = try table.forkReference(original);
    try std.testing.expectEqual(original, forked.shared);
    try std.testing.expectEqual(@as(u32, 2), (try table.get(original)).refcount);
    const private = try table.copyOnWrite(original, 0x2222);
    try std.testing.expect(private.slot != original.slot);
    try std.testing.expectEqual(@as(u32, 1), (try table.get(original)).refcount);
    try std.testing.expectEqual(@as(u64, 0x2222), (try table.get(private)).payload_tag);
}

test "sticky freeze never loses the exact reference count" {
    var table = Table(1){};
    const id = try table.allocate(7);
    table.slots[0].refcount = refcount_freeze - 1;
    const last_shared = try table.forkReference(id);
    try std.testing.expectEqual(id, last_shared.shared);
    const clone = try table.forkReference(id);
    try std.testing.expectEqual(id, clone.clone_required);
    try std.testing.expectEqual(refcount_freeze, table.slots[0].refcount);
    try std.testing.expect(table.slots[0].has(.frozen));
}

test "cache reclaim reuses the authoritative payload without a write" {
    var table = Table(1){};
    const id = try table.allocate(0xabcdef);
    try table.cacheFill(id, 0xabcdef);
    const writes = (try table.get(id)).writes;
    try table.reclaimCached(id);
    try std.testing.expectEqual(writes, (try table.get(id)).writes);
    try table.cacheFill(id, 0xabcdef);
    try std.testing.expectEqual(writes, (try table.get(id)).writes);
}

test "generation rejects an ABA after slot reuse" {
    var table = Table(1){};
    const first = try table.allocate(1);
    try table.release(first);
    const second = try table.allocate(2);
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expectError(error.StaleObject, table.cacheFill(first, 1));
}

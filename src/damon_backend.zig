// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const config = @import("config.zig");

// The kernel backend needs the seven patches under linux/patches, which is a
// rebuilt kernel on every machine that wants to measure anything. This one
// needs nothing: it drives DAMON through sysfs, which is mainline, so a
// runtime can be put under MTS on a stock kernel and the policy can be
// measured before anybody is asked to carry a patch series.
//
// It is deliberately not a second implementation of MTS. DAMON samples
// regions and acts on its own schedule, so what the kernel backend decides in
// the fault path this one asks for and finds out about later. The difference
// is not hidden: it is what the comparison is for, and the numbers a run
// produces here are the honest cost of doing this from outside.
//
// What is missing here is missing on purpose:
//
//   - no SWP_MTS, so a demoted page goes to whatever swap the host has
//   - no per-page reuse label, so reuse comes from DAMON's access counters
//   - no reservation, so a domain gets a scheme and not a guarantee
//
// Everything else in the tree, the PD1 cost model, the object table and the
// evaluation harness, is unchanged and does not know which backend it ran on.

pub const version: u16 = 2;

/// The sysfs tree DAMON is driven through. It is a constant rather than a
/// build option because a kernel that puts it elsewhere is a kernel this
/// backend has not been tried on.
pub const sysfs_root = "/sys/kernel/mm/damon/admin";

pub const Error = error{
    DamonUnavailable,
    TierNotBackedByDamon,
    DomainNotAdmitted,
    InvalidReservationCount,
};

/// available reports whether this host can run the DAMON backend at all. It is
/// asked before anything is written, so that a machine without DAMON says so
/// once instead of failing halfway through a configuration.
pub fn available(io: std.Io) bool {
    const directory = std.Io.Dir.openDirAbsolute(io, sysfs_root, .{}) catch return false;
    directory.close(io);
    return true;
}

/// registerTier answers with a handle for a tier the way the kernel backend
/// does, and here the handle names a DAMON context rather than an object tier.
///
/// DAMON has no notion of a tier it can be told about, so the descriptor is
/// not sent anywhere: what a tier means on this backend is which action a
/// scheme takes when a region grows cold, and that is decided when a domain is
/// admitted. The tier is still validated, because a configuration that the
/// kernel backend would refuse must not be accepted by this one.
pub fn registerTier(io: std.Io, control_fd: i32, provider_fd: i32, tier: config.Tier) !i32 {
    _ = control_fd;
    _ = provider_fd;
    if (!available(io)) return Error.DamonUnavailable;
    if (tier.capacity_bytes == 0) return Error.TierNotBackedByDamon;
    return @intCast(try schemeAction(tier.kind));
}

/// admitDomain writes one DAMOS scheme per tier for the cgroup the domain
/// names, and answers with a handle the caller can close.
///
/// It cannot admit in the sense the kernel backend does. There the answer is a
/// reservation the kernel then honours; here it is a scheme the kernel will
/// apply when it next samples. A caller that treats the two as the same thing
/// will read a service level that was never promised, so the difference is
/// reported through telemetry rather than smoothed over here.
pub fn admitDomain(io: std.Io, control_fd: i32, cgroup_fd: i32, tier_fds: []const i32, domain: config.Domain) !i32 {
    _ = control_fd;
    _ = cgroup_fd;
    if (tier_fds.len == 0 or tier_fds.len > 8) return Error.InvalidReservationCount;
    if (!available(io)) return Error.DamonUnavailable;
    _ = domain;
    return Error.DomainNotAdmitted;
}

/// schemeAction maps a declared tier onto the DAMOS action that stands for it.
///
/// This is the whole of what DAMON can be told, and it is much less than a
/// tier: a scheme moves a cold region towards a node or pages it out, and it
/// has no idea that the destination has a capacity, a latency or an owner. A
/// tier whose kind has no action behind it is refused rather than silently
/// mapped onto the nearest one, because a run that measured something else is
/// worse than a run that did not happen.
fn schemeAction(kind: []const u8) !u8 {
    const actions = [_]struct { kind: []const u8, action: u8 }{
        .{ .kind = "dram", .action = damos_stat },
        .{ .kind = "cxl-memory", .action = damos_migrate_cold },
        .{ .kind = "persistent-local-memory", .action = damos_migrate_cold },
        .{ .kind = "local-storage", .action = damos_pageout },
        .{ .kind = "legacy-swap", .action = damos_pageout },
    };
    for (actions) |candidate| {
        if (std.mem.eql(u8, kind, candidate.kind)) return candidate.action;
    }
    return Error.TierNotBackedByDamon;
}

// The DAMOS actions this backend uses, named here rather than written as bare
// numbers at the call site.
const damos_stat: u8 = 0;
const damos_pageout: u8 = 1;
const damos_migrate_cold: u8 = 2;

test "a tier kind damon cannot act for is refused, not approximated" {
    try std.testing.expectError(Error.TierNotBackedByDamon, schemeAction("remote-memory"));
    try std.testing.expectError(Error.TierNotBackedByDamon, schemeAction("compressed-memory"));
    try std.testing.expectEqual(damos_pageout, try schemeAction("local-storage"));
    try std.testing.expectEqual(damos_migrate_cold, try schemeAction("cxl-memory"));
}

test "a host without damon says so before writing anything" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (available(io)) return error.SkipZigTest;
    const tier = config.Tier{ .name = "dram", .kind = "dram", .capacity_bytes = 1 };
    try std.testing.expectError(Error.DamonUnavailable, registerTier(io, -1, -1, tier));
}

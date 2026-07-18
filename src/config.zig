// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub const max_tiers = 32;
pub const max_domains = 64;

pub const Mode = enum { off, observe, enforce };
pub const Lifetime = enum { persistent, fd_scoped };

pub const Tier = struct {
    name: []const u8,
    uuid: []const u8 = "",
    kind: []const u8 = "",
    provider: []const u8 = "",
    lifetime: ?Lifetime = null,
    capacity_bytes: u64 = 0,
    seen: u8 = 0,
};

pub const Domain = struct {
    path: []const u8,
    mode: ?Mode = null,
    tiers: []const u8 = "",
    fault_service_p99_us: ?u64 = null,
    reuse_horizon_us: u64 = 1_000_000,
    predictor: []const u8 = "iso16",
    controller: []const u8 = "pd1",
    seen: u8 = 0,
};

pub const Config = struct {
    version: ?u16 = null,
    mode: Mode = .off,
    global_seen: u8 = 0,
    tiers: [max_tiers]Tier = undefined,
    tier_count: usize = 0,
    domains: [max_domains]Domain = undefined,
    domain_count: usize = 0,
};

const SectionKind = enum { none, global, tier, domain, extension };
const Section = struct { kind: SectionKind = .none, index: usize = 0 };

pub const Diagnostic = struct {
    line: usize,
    key: []const u8,
    reason: Reason,
};

pub const Reason = enum {
    assignment_outside_section,
    bad_section,
    duplicate_section,
    duplicate_key,
    unknown_key,
    missing_equals,
    invalid_value,
    missing_required_key,
    unresolved_tier,
    limit_exceeded,
};

pub const ParseResult = union(enum) {
    config: Config,
    diagnostic: Diagnostic,
};

pub fn parse(input: []const u8) ParseResult {
    var config = Config{};
    var section = Section{};
    var lines = std.mem.splitScalar(u8, input, '\n');
    var line_number: usize = 0;

    while (lines.next()) |raw| {
        line_number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const next = parseSection(&config, line, line_number);
            switch (next) {
                .section => |value| section = value,
                .diagnostic => |value| return .{ .diagnostic = value },
            }
            continue;
        }

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse
            return failure(line_number, line, .missing_equals);
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (key.len == 0) return failure(line_number, key, .invalid_value);
        if (section.kind == .none) return failure(line_number, key, .assignment_outside_section);
        if (section.kind == .extension or std.mem.startsWith(u8, key, "X-")) continue;

        const diag = switch (section.kind) {
            .global => assignGlobal(&config, key, value, line_number),
            .tier => assignTier(&config.tiers[section.index], key, value, line_number),
            .domain => assignDomain(&config.domains[section.index], key, value, line_number),
            else => null,
        };
        if (diag) |value_diag| return .{ .diagnostic = value_diag };
    }

    if (config.version == null or config.version.? != 2)
        return failure(line_number, "Version", .missing_required_key);
    for (config.tiers[0..config.tier_count]) |tier| {
        if (tier.seen != 0x1f) return failure(line_number, tier.name, .missing_required_key);
    }
    for (config.domains[0..config.domain_count]) |domain| {
        if ((domain.seen & 0x03) != 0x03 or (domain.mode == .enforce and domain.fault_service_p99_us == null))
            return failure(line_number, domain.path, .missing_required_key);
        var names = std.mem.splitScalar(u8, domain.tiers, ',');
        while (names.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t");
            if (std.mem.eql(u8, name, "dram")) continue;
            if (!tierExists(config, name)) return failure(line_number, name, .unresolved_tier);
        }
    }
    return .{ .config = config };
}

const SectionResult = union(enum) { section: Section, diagnostic: Diagnostic };

fn parseSection(config: *Config, line: []const u8, line_number: usize) SectionResult {
    if (line.len < 3 or line[line.len - 1] != ']')
        return .{ .diagnostic = .{ .line = line_number, .key = line, .reason = .bad_section } };
    const body = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (std.mem.eql(u8, body, "MTS")) return .{ .section = .{ .kind = .global } };
    if (std.mem.startsWith(u8, body, "X-")) return .{ .section = .{ .kind = .extension } };

    const tier_name = quotedName(body, "Tier ");
    if (tier_name) |name| {
        if (config.tier_count == max_tiers)
            return .{ .diagnostic = .{ .line = line_number, .key = name, .reason = .limit_exceeded } };
        if (tierExists(config.*, name))
            return .{ .diagnostic = .{ .line = line_number, .key = name, .reason = .duplicate_section } };
        const index = config.tier_count;
        config.tiers[index] = .{ .name = name };
        config.tier_count += 1;
        return .{ .section = .{ .kind = .tier, .index = index } };
    }

    const domain_name = quotedName(body, "Domain ");
    if (domain_name) |name| {
        if (name.len == 0 or name[0] != '/')
            return .{ .diagnostic = .{ .line = line_number, .key = name, .reason = .invalid_value } };
        if (config.domain_count == max_domains)
            return .{ .diagnostic = .{ .line = line_number, .key = name, .reason = .limit_exceeded } };
        for (config.domains[0..config.domain_count]) |domain| {
            if (std.mem.eql(u8, domain.path, name))
                return .{ .diagnostic = .{ .line = line_number, .key = name, .reason = .duplicate_section } };
        }
        const index = config.domain_count;
        config.domains[index] = .{ .path = name };
        config.domain_count += 1;
        return .{ .section = .{ .kind = .domain, .index = index } };
    }
    return .{ .diagnostic = .{ .line = line_number, .key = body, .reason = .bad_section } };
}

fn quotedName(body: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, body, prefix)) return null;
    const rest = body[prefix.len..];
    if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') return null;
    const name = rest[1 .. rest.len - 1];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '"') != null) return null;
    return name;
}

fn assignGlobal(config: *Config, key: []const u8, value: []const u8, line: usize) ?Diagnostic {
    if (std.mem.eql(u8, key, "Version")) {
        if (!mark(&config.global_seen, 0x01)) return duplicate(line, key);
        config.version = std.fmt.parseInt(u16, value, 10) catch return invalid(line, key);
    } else if (std.mem.eql(u8, key, "Mode")) {
        if (!mark(&config.global_seen, 0x02)) return duplicate(line, key);
        config.mode = parseMode(value) orelse return invalid(line, key);
    } else return unknown(line, key);
    return null;
}

fn assignTier(tier: *Tier, key: []const u8, value: []const u8, line: usize) ?Diagnostic {
    if (std.mem.eql(u8, key, "UUID")) {
        if (!mark(&tier.seen, 0x01)) return duplicate(line, key);
        if (!validUuid(value)) return invalid(line, key);
        tier.uuid = value;
    } else if (std.mem.eql(u8, key, "Kind")) {
        if (!mark(&tier.seen, 0x02)) return duplicate(line, key);
        if (!validKind(value)) return invalid(line, key);
        tier.kind = value;
    } else if (std.mem.eql(u8, key, "Provider")) {
        if (!mark(&tier.seen, 0x04)) return duplicate(line, key);
        if (value.len == 0) return invalid(line, key);
        tier.provider = value;
    } else if (std.mem.eql(u8, key, "Flags")) {
        if (!mark(&tier.seen, 0x08)) return duplicate(line, key);
        tier.lifetime = if (std.mem.eql(u8, value, "persistent")) .persistent else if (std.mem.eql(u8, value, "fd-scoped")) .fd_scoped else return invalid(line, key);
    } else if (std.mem.eql(u8, key, "CapacityBytes")) {
        if (!mark(&tier.seen, 0x10)) return duplicate(line, key);
        tier.capacity_bytes = std.fmt.parseInt(u64, value, 10) catch return invalid(line, key);
        if (tier.capacity_bytes == 0) return invalid(line, key);
    } else return unknown(line, key);
    return null;
}

fn assignDomain(domain: *Domain, key: []const u8, value: []const u8, line: usize) ?Diagnostic {
    if (std.mem.eql(u8, key, "Mode")) {
        if (!mark(&domain.seen, 0x01)) return duplicate(line, key);
        domain.mode = parseMode(value) orelse return invalid(line, key);
    } else if (std.mem.eql(u8, key, "Tiers")) {
        if (!mark(&domain.seen, 0x02)) return duplicate(line, key);
        if (value.len == 0) return invalid(line, key);
        domain.tiers = value;
    } else if (std.mem.eql(u8, key, "FaultServiceP99USec")) {
        if (!mark(&domain.seen, 0x04)) return duplicate(line, key);
        domain.fault_service_p99_us = std.fmt.parseInt(u64, value, 10) catch return invalid(line, key);
        if (domain.fault_service_p99_us.? == 0) return invalid(line, key);
    } else if (std.mem.eql(u8, key, "ReuseHorizonUSec")) {
        if (!mark(&domain.seen, 0x08)) return duplicate(line, key);
        domain.reuse_horizon_us = std.fmt.parseInt(u64, value, 10) catch return invalid(line, key);
        if (domain.reuse_horizon_us == 0) return invalid(line, key);
    } else if (std.mem.eql(u8, key, "Predictor")) {
        if (!mark(&domain.seen, 0x10)) return duplicate(line, key);
        if (!std.mem.eql(u8, value, "iso16")) return invalid(line, key);
        domain.predictor = value;
    } else if (std.mem.eql(u8, key, "Controller")) {
        if (!mark(&domain.seen, 0x20)) return duplicate(line, key);
        if (!std.mem.eql(u8, value, "pd1")) return invalid(line, key);
        domain.controller = value;
    } else return unknown(line, key);
    return null;
}

fn parseMode(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "observe")) return .observe;
    if (std.mem.eql(u8, value, "enforce")) return .enforce;
    return null;
}

fn validKind(value: []const u8) bool {
    const values = [_][]const u8{
        "compressed-memory", "persistent-local-memory", "cxl-memory",
        "local-storage",     "remote-memory",           "legacy-swap",
    };
    for (values) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn validUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |char, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (char != '-') return false;
        } else if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

fn tierExists(config: Config, name: []const u8) bool {
    for (config.tiers[0..config.tier_count]) |tier| {
        if (std.mem.eql(u8, tier.name, name)) return true;
    }
    return false;
}

fn mark(seen: *u8, bit: u8) bool {
    if (seen.* & bit != 0) return false;
    seen.* |= bit;
    return true;
}

fn failure(line: usize, key: []const u8, reason: Reason) ParseResult {
    return .{ .diagnostic = .{ .line = line, .key = key, .reason = reason } };
}

fn duplicate(line: usize, key: []const u8) Diagnostic {
    return .{ .line = line, .key = key, .reason = .duplicate_key };
}
fn invalid(line: usize, key: []const u8) Diagnostic {
    return .{ .line = line, .key = key, .reason = .invalid_value };
}
fn unknown(line: usize, key: []const u8) Diagnostic {
    return .{ .line = line, .key = key, .reason = .unknown_key };
}

test "portable config validates a complete observe domain" {
    const text =
        \\[MTS]
        \\Version=2
        \\Mode=observe
        \\[Tier "nvme"]
        \\UUID=018f3f28-7ee0-7dd2-a400-8f847e14c001
        \\Kind=local-storage
        \\Provider=/dev/nvme0n1
        \\Flags=persistent
        \\CapacityBytes=1099511627776
        \\[Domain "/redis"]
        \\Mode=observe
        \\Tiers=dram,nvme
    ;
    const result = parse(text);
    switch (result) {
        .config => |config| {
            try std.testing.expectEqual(@as(usize, 1), config.tier_count);
            try std.testing.expectEqual(@as(usize, 1), config.domain_count);
        },
        .diagnostic => return error.UnexpectedDiagnostic,
    }
}

test "duplicate keys reject the complete file" {
    const result = parse("[MTS]\nVersion=2\nVersion=2\n");
    switch (result) {
        .config => return error.ExpectedDiagnostic,
        .diagnostic => |diag| try std.testing.expectEqual(Reason.duplicate_key, diag.reason),
    }
}

test "enforce requires an explicit fault SLO" {
    const result = parse("[MTS]\nVersion=2\n[Domain \"/x\"]\nMode=enforce\nTiers=dram\n");
    switch (result) {
        .config => return error.ExpectedDiagnostic,
        .diagnostic => |diag| try std.testing.expectEqual(Reason.missing_required_key, diag.reason),
    }
}

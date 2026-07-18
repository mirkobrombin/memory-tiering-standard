// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const eval_result = @import("eval_result.zig");

pub const schema = "mts-eval-identity/v0.2";
pub const required_keys = [_][]const u8{
    "manifest_sha256",
    "kernel_build_id",
    "firmware_versions",
    "cpu_topology",
    "numa_topology",
    "nvme_model_and_firmware",
    "compiler_version",
    "source_digests",
    "sysctl_diff",
    "module_parameters",
};

pub const Identity = struct {
    values: [required_keys.len][]const u8 = @splat(""),
};

const header = "schema\tkey\tvalue";

fn keyIndex(key: []const u8) ?usize {
    for (required_keys, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, key)) return index;
    }
    return null;
}

pub fn parse(input: []const u8) !Identity {
    var identity = Identity{};
    var lines = std.mem.splitScalar(u8, input, '\n');
    const first = std.mem.trim(u8, lines.next() orelse return error.MissingHeader, " \t\r");
    if (!std.mem.eql(u8, first, header)) return error.InvalidHeader;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields: [3][]const u8 = undefined;
        var count: usize = 0;
        var split = std.mem.splitScalar(u8, line, '\t');
        while (split.next()) |field| {
            if (count == fields.len) return error.TooManyFields;
            fields[count] = field;
            count += 1;
        }
        if (count != fields.len) return error.MissingField;
        if (!std.mem.eql(u8, fields[0], schema)) return error.InvalidSchema;
        const index = keyIndex(fields[1]) orelse return error.UnknownIdentityKey;
        if (identity.values[index].len != 0) return error.DuplicateIdentityKey;
        if (fields[2].len == 0) return error.EmptyIdentityValue;
        identity.values[index] = fields[2];
    }
    for (identity.values) |value| {
        if (value.len == 0) return error.MissingIdentityKey;
    }
    if (!std.mem.eql(u8, identity.values[0], eval_result.manifest_sha256))
        return error.ManifestDigestMismatch;
    return identity;
}

test "identity requires the frozen manifest digest" {
    const input =
        "schema\tkey\tvalue\n" ++
        "mts-eval-identity/v0.2\tmanifest_sha256\twrong\n";
    try std.testing.expectError(error.MissingIdentityKey, parse(input));
}

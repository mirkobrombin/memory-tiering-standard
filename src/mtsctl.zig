// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const command = @import("command.zig");
const feasibility = @import("feasibility.zig");
const calibrate = @import("calibrate.zig");
const config = @import("config.zig");

fn usage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll(
        "usage: mtsctl validate <mts.conf>\n" ++
            "       mtsctl apply <mts.conf>\n" ++
            "       mtsctl feasibility <compute_s> <read_B> <write_B> <io_count> " ++
            "<read_Bps> <write_Bps> <recover_p50_s> <qd> <critical_s> <work> <full_ram_q>\n" ++
            "       mtsctl calibrate <mts.conf> <tier> <out.conf>\n",
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};
    if (args.len < 2) {
        try usage(stderr);
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, args[1], "validate")) {
        if (args.len != 3) {
            try usage(stderr);
            return error.InvalidArguments;
        }
        return command.validate(init.io, allocator, args[2], stdout, stderr);
    }
    if (std.mem.eql(u8, args[1], "apply")) {
        if (args.len != 3) {
            try usage(stderr);
            return error.InvalidArguments;
        }
        const loaded = try command.loadAndValidate(init.io, allocator, args[2], stderr);
        defer loaded.deinit();
        return command.applyConfig(init.io, allocator, loaded, false, stdout, stderr);
    }
    if (std.mem.eql(u8, args[1], "feasibility")) {
        if (args.len != 13) {
            try usage(stderr);
            return error.InvalidArguments;
        }
        var values: [11]f64 = undefined;
        for (args[2..], 0..) |arg, index| values[index] = try std.fmt.parseFloat(f64, arg);
        const result = try feasibility.calculate(.{
            .compute_seconds = values[0],
            .read_bytes = values[1],
            .write_bytes = values[2],
            .io_count = values[3],
            .read_bandwidth_bytes_s = values[4],
            .write_bandwidth_bytes_s = values[5],
            .recover_p50_seconds = values[6],
            .qd_max = values[7],
            .critical_seconds = values[8],
            .completed_work_units = values[9],
        });
        try stdout.print(
            "T_floor={d:.9} Q_oracle={d:.9} threshold={d:.9}\n",
            .{ result.floor_seconds, result.oracle_throughput, result.threshold(values[10]) },
        );
        return;
    }
    if (std.mem.eql(u8, args[1], "calibrate")) {
        if (args.len != 5) {
            try usage(stderr);
            return error.InvalidArguments;
        }
        return runCalibrate(init.io, allocator, args[2], args[3], args[4], stdout, stderr);
    }
    try usage(stderr);
    return error.InvalidArguments;
}

fn runCalibrate(
    io: std.Io,
    allocator: std.mem.Allocator,
    in_path: []const u8,
    tier: []const u8,
    out_path: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const input = try std.Io.Dir.cwd().readFileAlloc(io, in_path, allocator, .limited(command.max_config_bytes));
    const provider = calibrate.providerOf(input, tier) orelse {
        try stderr.print("{s}: tier \"{s}\" has no Provider\n", .{ in_path, tier });
        return error.InvalidConfiguration;
    };
    const provider_z = try allocator.dupeZ(u8, provider);
    const m = try calibrate.measure(allocator, provider_z);
    const output = try calibrate.rewrite(allocator, input, tier, m);
    switch (config.parse(output)) {
        .config => {},
        .diagnostic => |diag| {
            try stderr.print("{s}:{d}: {s}: {s}\n", .{ out_path, diag.line, @tagName(diag.reason), diag.key });
            return error.InvalidConfiguration;
        },
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = output });
    try stdout.print(
        "{s}: read p50={d}ns p99={d}ns write p50={d}ns p99={d}ns read={d}B/s write={d}B/s direct={}\n",
        .{
            tier,                      m.read_latency_p50_ns,  m.read_latency_p99_ns,
            m.write_latency_p50_ns,    m.write_latency_p99_ns, m.read_bandwidth_bytes_s,
            m.write_bandwidth_bytes_s, m.direct,
        },
    );
}

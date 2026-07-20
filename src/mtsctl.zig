// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const command = @import("command.zig");
const feasibility = @import("feasibility.zig");

fn usage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll(
        "usage: mtsctl validate <mts.conf>\n" ++
            "       mtsctl apply <mts.conf>\n" ++
            "       mtsctl feasibility <compute_s> <read_B> <write_B> <io_count> " ++
            "<read_Bps> <write_Bps> <recover_p50_s> <qd> <critical_s> <work> <full_ram_q>\n",
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
    try usage(stderr);
    return error.InvalidArguments;
}

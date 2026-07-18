// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const eval_identity = @import("eval_identity.zig");
const eval_result = @import("eval_result.zig");
const mrc = @import("mrc.zig");

fn usage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll(
        "usage: mts-eval m0 <runs.tsv>\n" ++
            "       mts-eval v0.2 <runs.tsv> <identity.tsv>\n" ++
            "       mts-eval mrc <capacity_pages> <page-trace.txt>\n",
    );
}

fn load(init: std.process.Init, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        allocator,
        .limited(4 * 1024 * 1024),
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

    if (args.len < 3) {
        try usage(stderr);
        return error.InvalidArguments;
    }
    if (std.mem.eql(u8, args[1], "mrc")) {
        if (args.len != 4) {
            try usage(stderr);
            return error.InvalidArguments;
        }
        const capacity = try std.fmt.parseInt(u64, args[2], 0);
        const trace_bytes = try load(init, allocator, args[3]);
        const pages = try mrc.parseTrace(allocator, trace_bytes);
        const point = try mrc.atCapacity(allocator, pages, capacity);
        try stdout.print(
            "schema mts-mrc-point/v0.2\ncapacity_pages {d}\naccesses {d}\n" ++
                "misses {d}\nmiss_rate {d:.9}\nlower95 {d:.9}\nupper95 {d:.9}\n" ++
                "relative_half_width {d:.9}\nstatus {s}\n",
            .{
                capacity,
                point.accesses,
                point.misses,
                point.miss_rate,
                point.lower95,
                point.upper95,
                point.relativeHalfWidth(),
                if (point.relativeHalfWidth() <= 0.05) "VALID" else "INVALID",
            },
        );
        if (point.relativeHalfWidth() > 0.05) return error.ImpreciseMrc;
        return;
    }
    const bytes = try load(init, allocator, args[2]);
    const dataset = eval_result.parse(bytes) catch |err| {
        try stderr.print("{s}: {s}\n", .{ args[2], @errorName(err) });
        return error.InvalidResultArtifact;
    };
    if (std.mem.eql(u8, args[1], "v0.2")) {
        if (args.len != 4) {
            try usage(stderr);
            return error.InvalidArguments;
        }
        const identity_bytes = try load(init, allocator, args[3]);
        _ = eval_identity.parse(identity_bytes) catch |err| {
            try stderr.print("{s}: {s}\n", .{ args[3], @errorName(err) });
            return error.InvalidIdentityArtifact;
        };
        const report = eval_result.evaluateV02(dataset, allocator) catch |err| {
            try stderr.print("{s}: v0.2 evaluation failed: {s}\n", .{ args[2], @errorName(err) });
            return error.InvalidResultArtifact;
        };
        try stdout.writeAll("schema mts-eval-report/v0.2\n");
        for (report.workloads) |workload| {
            try stdout.print(
                "workload {s} fault_ratio={d:.9} fault_lower95={d:.9} " ++
                    "fault_upper95={d:.9} fault_median={d:.9} " ++
                    "throughput_margin={d:.9} throughput_lower95={d:.9} " ++
                    "throughput_upper95={d:.9} throughput_median={d:.9} status={s}\n",
                .{
                    workload.name,
                    workload.fault_ratio.estimate,
                    workload.fault_ratio.lower,
                    workload.fault_ratio.upper,
                    workload.fault_ratio_median,
                    workload.throughput_margin.estimate,
                    workload.throughput_margin.lower,
                    workload.throughput_margin.upper,
                    workload.throughput_margin_median,
                    if (workload.passed) "PASS" else "FAIL",
                },
            );
        }
        try stdout.print(
            "correctness_failures {d}\nintegrity_failures {d}\n" ++
                "admitted_slo_violations {d}\nstatus {s}\n",
            .{
                report.correctness_failures,
                report.integrity_failures,
                report.slo_violations,
                if (report.passed) "PASS" else "FAIL",
            },
        );
        if (!report.passed) return error.GateFailed;
        return;
    }
    if (!std.mem.eql(u8, args[1], "m0") or args.len != 3) {
        try usage(stderr);
        return error.InvalidArguments;
    }
    const report = eval_result.evaluateM0(dataset, allocator) catch |err| {
        try stderr.print("{s}: M0 evaluation failed: {s}\n", .{ args[2], @errorName(err) });
        return error.InvalidResultArtifact;
    };
    try stdout.print(
        "schema mts-eval-m0-report/v0.2\n" ++
            "throughput_ratio estimate={d:.9} lower95={d:.9} upper95={d:.9} threshold=0.995000000\n" ++
            "brier_skill estimate={d:.9} lower95={d:.9} upper95={d:.9} threshold=0.000000000\n" ++
            "correctness_failures {d}\nstatus {s}\n",
        .{
            report.throughput_ratio.estimate,
            report.throughput_ratio.lower,
            report.throughput_ratio.upper,
            report.brier_skill.estimate,
            report.brier_skill.lower,
            report.brier_skill.upper,
            report.correctness_failures,
            if (report.passed) "PASS" else "FAIL",
        },
    );
    if (!report.passed) return error.GateFailed;
}

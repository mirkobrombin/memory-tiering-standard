// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const statistics = @import("statistics.zig");

pub const schema = "mts-eval-run/v0.2";
pub const repetitions = 5;
pub const manifest_seed: u64 = 0x4d54533032;
pub const minimum_labels: u64 = 10_000;
pub const manifest_sha256 = "859063d710f6497ed0e8fa228406118fa705cab1e24485dea19c3b00a3e51a66";
pub const workload_names = [_][]const u8{ "redis-zipf", "jvm-graph", "torch-train" };
pub const configuration_names = [_][]const u8{
    "full-ram",
    "zram-mglru",
    "zswap-writeback",
    "mts-pd1",
    "mts-pd1-comp",
};

pub const Run = struct {
    workload: []const u8,
    configuration: []const u8,
    repetition: u8,
    throughput: f64,
    fault_p99_us: f64,
    pressure_ratio: f64,
    admitted: bool,
    slo_violations: u64,
    correctness_failures: u64,
    integrity_failures: u64,
    prediction_labels: u64,
    prediction_brier_sum_q32: u64,
    positive_labels: u64,
    oracle_throughput: f64,
    mrc_relative_half_width: f64,
};

pub const max_runs = 128;

pub const Dataset = struct {
    runs: [max_runs]Run = undefined,
    count: usize = 0,
};

const header = "schema\tworkload\tconfiguration\trepetition\tthroughput\t" ++
    "fault_p99_us\tpressure_ratio\tadmitted\tslo_violations\t" ++
    "correctness_failures\tintegrity_failures\tprediction_labels\t" ++
    "prediction_brier_sum_q32\tpositive_labels\toracle_throughput\t" ++
    "mrc_relative_half_width";

pub fn parse(input: []const u8) !Dataset {
    var dataset = Dataset{};
    var lines = std.mem.splitScalar(u8, input, '\n');
    const first = std.mem.trim(u8, lines.next() orelse return error.MissingHeader, " \t\r");
    if (!std.mem.eql(u8, first, header)) return error.InvalidHeader;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (dataset.count == max_runs) return error.TooManyRuns;
        var fields: [16][]const u8 = undefined;
        var field_count: usize = 0;
        var split = std.mem.splitScalar(u8, line, '\t');
        while (split.next()) |field| {
            if (field_count == fields.len) return error.TooManyFields;
            fields[field_count] = field;
            field_count += 1;
        }
        if (field_count != fields.len) return error.MissingField;
        if (!std.mem.eql(u8, fields[0], schema)) return error.InvalidSchema;

        const run = Run{
            .workload = fields[1],
            .configuration = fields[2],
            .repetition = try std.fmt.parseInt(u8, fields[3], 10),
            .throughput = try std.fmt.parseFloat(f64, fields[4]),
            .fault_p99_us = try std.fmt.parseFloat(f64, fields[5]),
            .pressure_ratio = try std.fmt.parseFloat(f64, fields[6]),
            .admitted = try parseBool(fields[7]),
            .slo_violations = try std.fmt.parseInt(u64, fields[8], 10),
            .correctness_failures = try std.fmt.parseInt(u64, fields[9], 10),
            .integrity_failures = try std.fmt.parseInt(u64, fields[10], 10),
            .prediction_labels = try std.fmt.parseInt(u64, fields[11], 10),
            .prediction_brier_sum_q32 = try std.fmt.parseInt(u64, fields[12], 10),
            .positive_labels = try std.fmt.parseInt(u64, fields[13], 10),
            .oracle_throughput = try std.fmt.parseFloat(f64, fields[14]),
            .mrc_relative_half_width = try std.fmt.parseFloat(f64, fields[15]),
        };
        if (run.repetition == 0 or run.repetition > repetitions or
            !std.math.isFinite(run.throughput) or run.throughput <= 0 or
            !std.math.isFinite(run.fault_p99_us) or run.fault_p99_us < 0 or
            !std.math.isFinite(run.pressure_ratio) or run.pressure_ratio < 0 or
            !std.math.isFinite(run.oracle_throughput) or run.oracle_throughput < 0 or
            !std.math.isFinite(run.mrc_relative_half_width) or run.mrc_relative_half_width < 0 or
            run.positive_labels > run.prediction_labels)
            return error.InvalidRun;
        dataset.runs[dataset.count] = run;
        dataset.count += 1;
    }
    if (dataset.count == 0) return error.EmptyDataset;
    return dataset;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}

pub const M0Report = struct {
    throughput_ratio: statistics.Interval,
    brier_skill: statistics.Interval,
    correctness_failures: u64,
    passed: bool,
};

pub const WorkloadReport = struct {
    name: []const u8,
    fault_ratio: statistics.Interval,
    fault_ratio_median: f64,
    throughput_margin: statistics.Interval,
    throughput_margin_median: f64,
    passed: bool,
};

pub const V02Report = struct {
    workloads: [workload_names.len]WorkloadReport,
    correctness_failures: u64,
    integrity_failures: u64,
    slo_violations: u64,
    passed: bool,
};

pub fn evaluateM0(dataset: Dataset, allocator: std.mem.Allocator) !M0Report {
    var full_ram: [repetitions]f64 = undefined;
    var observe: [repetitions]f64 = undefined;
    var skills: [repetitions]f64 = undefined;
    var have_full: [repetitions]bool = @splat(false);
    var have_observe: [repetitions]bool = @splat(false);
    var failures: u64 = 0;

    for (dataset.runs[0..dataset.count]) |run| {
        if (!std.mem.eql(u8, run.workload, "redis-zipf")) continue;
        const index = run.repetition - 1;
        failures += run.correctness_failures;
        if (std.mem.eql(u8, run.configuration, "full-ram")) {
            if (have_full[index]) return error.DuplicateRepetition;
            have_full[index] = true;
            full_ram[index] = run.throughput;
        } else if (std.mem.eql(u8, run.configuration, "mts-observe")) {
            if (have_observe[index]) return error.DuplicateRepetition;
            if (run.prediction_labels < minimum_labels) return error.InsufficientLabels;
            const labels: f64 = @floatFromInt(run.prediction_labels);
            const brier = (@as(f64, @floatFromInt(run.prediction_brier_sum_q32)) /
                4_294_967_296.0) / labels;
            const rate = @as(f64, @floatFromInt(run.positive_labels)) / labels;
            const base_brier = rate * (1.0 - rate);
            if (base_brier <= 0) return error.DegenerateBaseRate;
            skills[index] = 1.0 - brier / base_brier;
            have_observe[index] = true;
            observe[index] = run.throughput;
        }
    }
    for (0..repetitions) |index| {
        if (!have_full[index] or !have_observe[index]) return error.MissingRepetition;
    }

    const ratio = try statistics.pairedRatio(
        allocator,
        &observe,
        &full_ram,
        manifest_seed ^ 0x7468726f75676870,
    );
    const skill = try statistics.meanInterval(
        allocator,
        &skills,
        manifest_seed ^ 0x6272696572,
    );
    return .{
        .throughput_ratio = ratio,
        .brier_skill = skill,
        .correctness_failures = failures,
        .passed = ratio.lower >= 0.995 and skill.lower > 0 and failures == 0,
    };
}

fn nameIndex(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) return index;
    }
    return null;
}

fn median(values: [repetitions]f64) f64 {
    var sorted = values;
    std.mem.sort(f64, &sorted, {}, std.sort.asc(f64));
    return sorted[repetitions / 2];
}

pub fn evaluateV02(dataset: Dataset, allocator: std.mem.Allocator) !V02Report {
    var table: [workload_names.len][configuration_names.len][repetitions]Run = undefined;
    var have: [workload_names.len][configuration_names.len][repetitions]bool = @splat(@splat(@splat(false)));
    var correctness_failures: u64 = 0;
    var integrity_failures: u64 = 0;
    var slo_violations: u64 = 0;

    for (dataset.runs[0..dataset.count]) |run| {
        const workload = nameIndex(&workload_names, run.workload) orelse
            return error.UnknownWorkload;
        const configuration = nameIndex(&configuration_names, run.configuration) orelse
            return error.UnknownConfiguration;
        const repetition = run.repetition - 1;
        if (have[workload][configuration][repetition]) return error.DuplicateRepetition;
        have[workload][configuration][repetition] = true;
        table[workload][configuration][repetition] = run;
        correctness_failures += run.correctness_failures;
        integrity_failures += run.integrity_failures;

        if (configuration != 0 and
            (run.pressure_ratio < 1.48 or run.pressure_ratio > 1.52))
            return error.InvalidPressure;
        if (configuration == 3 or configuration == 4) {
            if (!run.admitted) return error.NotAdmitted;
            if (run.mrc_relative_half_width > 0.05) return error.ImpreciseMrc;
            if (run.oracle_throughput <= 0) return error.MissingOracle;
            slo_violations += run.slo_violations;
        }
    }
    for (0..workload_names.len) |workload| {
        for (0..configuration_names.len) |configuration| {
            for (0..repetitions) |repetition| {
                if (!have[workload][configuration][repetition])
                    return error.MissingRepetition;
            }
        }
    }

    var reports: [workload_names.len]WorkloadReport = undefined;
    var all_passed = correctness_failures == 0 and
        integrity_failures == 0 and slo_violations == 0;
    for (0..workload_names.len) |workload| {
        var mts_fault: [repetitions]f64 = undefined;
        var zswap_fault: [repetitions]f64 = undefined;
        var fault_ratios: [repetitions]f64 = undefined;
        var throughput_margins: [repetitions]f64 = undefined;
        for (0..repetitions) |repetition| {
            const full_ram = table[workload][0][repetition];
            const zswap = table[workload][2][repetition];
            const mts = table[workload][3][repetition];
            if (zswap.fault_p99_us <= 0) return error.InvalidBaselineFaultLatency;
            mts_fault[repetition] = mts.fault_p99_us;
            zswap_fault[repetition] = zswap.fault_p99_us;
            fault_ratios[repetition] = mts.fault_p99_us / zswap.fault_p99_us;
            const threshold = @min(
                0.95 * full_ram.throughput,
                0.97 * mts.oracle_throughput,
            );
            if (threshold <= 0) return error.InvalidThroughputThreshold;
            throughput_margins[repetition] = mts.throughput / threshold;
        }
        const fault = try statistics.pairedRatio(
            allocator,
            &mts_fault,
            &zswap_fault,
            manifest_seed ^ 0x6661756c74 ^ workload,
        );
        const throughput = try statistics.meanInterval(
            allocator,
            &throughput_margins,
            manifest_seed ^ 0x7468727074 ^ workload,
        );
        const fault_median = median(fault_ratios);
        const throughput_median = median(throughput_margins);
        const passed = fault.upper <= 0.50 and fault_median <= 0.50 and
            throughput.lower >= 1.0 and throughput_median >= 1.0;
        reports[workload] = .{
            .name = workload_names[workload],
            .fault_ratio = fault,
            .fault_ratio_median = fault_median,
            .throughput_margin = throughput,
            .throughput_margin_median = throughput_median,
            .passed = passed,
        };
        all_passed = all_passed and passed;
    }
    return .{
        .workloads = reports,
        .correctness_failures = correctness_failures,
        .integrity_failures = integrity_failures,
        .slo_violations = slo_violations,
        .passed = all_passed,
    };
}

test "M0 evaluation rejects incomplete replay sets" {
    var dataset = Dataset{};
    dataset.runs[0] = .{
        .workload = "redis-zipf",
        .configuration = "full-ram",
        .repetition = 1,
        .throughput = 100,
        .fault_p99_us = 0,
        .pressure_ratio = 0,
        .admitted = false,
        .slo_violations = 0,
        .correctness_failures = 0,
        .integrity_failures = 0,
        .prediction_labels = 0,
        .prediction_brier_sum_q32 = 0,
        .positive_labels = 0,
        .oracle_throughput = 0,
        .mrc_relative_half_width = 0,
    };
    dataset.count = 1;
    try std.testing.expectError(error.MissingRepetition, evaluateM0(dataset, std.testing.allocator));
}

test "complete v0.2 evaluation accepts all controlling gates" {
    var dataset = Dataset{};
    for (workload_names) |workload| {
        for (configuration_names, 0..) |configuration, configuration_index| {
            for (1..repetitions + 1) |repetition| {
                const full_throughput: f64 = 100_000;
                var throughput = full_throughput;
                var fault_p99_us: f64 = 0;
                if (configuration_index == 2) fault_p99_us = 300;
                if (configuration_index == 3) {
                    throughput = 97_000;
                    fault_p99_us = 140;
                }
                dataset.runs[dataset.count] = .{
                    .workload = workload,
                    .configuration = configuration,
                    .repetition = @intCast(repetition),
                    .throughput = throughput,
                    .fault_p99_us = fault_p99_us,
                    .pressure_ratio = if (configuration_index == 0) 0 else 1.5,
                    .admitted = configuration_index == 3 or configuration_index == 4,
                    .slo_violations = 0,
                    .correctness_failures = 0,
                    .integrity_failures = 0,
                    .prediction_labels = 0,
                    .prediction_brier_sum_q32 = 0,
                    .positive_labels = 0,
                    .oracle_throughput = if (configuration_index == 3 or configuration_index == 4) 100_000 else 0,
                    .mrc_relative_half_width = if (configuration_index == 3 or configuration_index == 4) 0.04 else 0,
                };
                dataset.count += 1;
            }
        }
    }
    const report = try evaluateV02(dataset, std.testing.allocator);
    try std.testing.expect(report.passed);
    for (report.workloads) |workload| try std.testing.expect(workload.passed);
}

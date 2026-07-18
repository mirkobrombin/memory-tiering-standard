// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const workload = @import("workload.zig");

fn usage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll("usage: mts-workload <redis-zipf|jvm-graph|torch-train> <events> <keys> <seed> <repetition>\n");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    defer stdout.flush() catch {};
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stderr.flush() catch {};
    if (args.len != 6) {
        try usage(stderr);
        return error.InvalidArguments;
    }
    const kind: workload.Kind = if (std.mem.eql(u8, args[1], "redis-zipf"))
        .redis_zipf
    else if (std.mem.eql(u8, args[1], "jvm-graph"))
        .jvm_graph
    else if (std.mem.eql(u8, args[1], "torch-train"))
        .torch_train
    else {
        try usage(stderr);
        return error.InvalidWorkload;
    };
    const events = try std.fmt.parseInt(u64, args[2], 10);
    const keys = try std.fmt.parseInt(u64, args[3], 10);
    const seed = try std.fmt.parseInt(u64, args[4], 0);
    const repetition = try std.fmt.parseInt(u64, args[5], 10);
    var generator = try workload.Generator.init(allocator, kind, keys, seed ^ repetition);
    defer generator.deinit();
    for (0..events) |_| try stdout.print("{d}\n", .{generator.next()});
}

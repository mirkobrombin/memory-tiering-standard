// SPDX-License-Identifier: MIT
const std = @import("std");
const command = @import("command.zig");

const default_config = "/etc/mts/mts.conf";

fn writeUnit(io: std.Io, output_dir: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/mtsd.service", .{output_dir});
    const unit =
        \\[Unit]
        \\Description=Memory Tiering Standard manager
        \\Documentation=man:mts.conf(5)
        \\DefaultDependencies=no
        \\After=local-fs.target
        \\Before=basic.target
        \\
        \\[Service]
        \\Type=oneshot
        \\RemainAfterExit=yes
        \\ExecStart=/usr/libexec/mtsd apply /etc/mts/mts.conf
        \\
        \\[Install]
        \\WantedBy=basic.target
        \\
    ;
    try std.Io.Dir.cwd().createDirPath(io, output_dir);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try file_writer.interface.writeAll(unit);
    try file_writer.interface.flush();
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

    if (args.len == 3 and std.mem.eql(u8, args[1], "--validate"))
        return command.validate(init.io, allocator, args[2], stdout, stderr);

    // systemd passes normal, early and late output directories. MTS emits only
    // into the normal directory so local administrators retain normal override rules.
    if (args.len != 4) return error.InvalidArguments;
    const loaded = command.loadAndValidate(init.io, allocator, default_config, stderr) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer loaded.deinit();
    try writeUnit(init.io, args[1]);
}

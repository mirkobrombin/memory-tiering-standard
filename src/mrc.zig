// SPDX-License-Identifier: Apache-2.0
const std = @import("std");

pub const Point = struct {
    accesses: u64,
    misses: u64,
    miss_rate: f64,
    lower95: f64,
    upper95: f64,

    pub fn relativeHalfWidth(self: Point) f64 {
        if (self.miss_rate == 0) return std.math.inf(f64);
        return (self.upper95 - self.lower95) / (2.0 * self.miss_rate);
    }
};

pub fn parseTrace(allocator: std.mem.Allocator, input: []const u8) ![]u64 {
    var count: usize = 0;
    var count_lines = std.mem.splitScalar(u8, input, '\n');
    while (count_lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len != 0 and line[0] != '#') count += 1;
    }
    if (count == 0) return error.EmptyTrace;
    const pages = try allocator.alloc(u64, count);
    errdefer allocator.free(pages);
    var index: usize = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        pages[index] = try std.fmt.parseInt(u64, line, 0);
        index += 1;
    }
    return pages;
}

const Fenwick = struct {
    tree: []u64,

    fn add(self: Fenwick, one_based_index: usize, delta: i8) void {
        var index = one_based_index;
        while (index < self.tree.len) : (index += index & (~index +% 1)) {
            if (delta > 0) {
                self.tree[index] += 1;
            } else {
                self.tree[index] -= 1;
            }
        }
    }

    fn prefix(self: Fenwick, one_based_index: usize) u64 {
        var index = one_based_index;
        var sum: u64 = 0;
        while (index != 0) : (index &= index - 1) sum += self.tree[index];
        return sum;
    }
};

pub fn atCapacity(
    allocator: std.mem.Allocator,
    page_ids: []const u64,
    capacity_pages: u64,
) !Point {
    if (page_ids.len == 0 or capacity_pages == 0) return error.InvalidMrcInput;
    const tree = try allocator.alloc(u64, page_ids.len + 1);
    defer allocator.free(tree);
    @memset(tree, 0);
    var fenwick = Fenwick{ .tree = tree };
    var last = std.AutoHashMap(u64, usize).init(allocator);
    defer last.deinit();
    try last.ensureTotalCapacity(@intCast(@min(page_ids.len, 1_048_576)));

    var misses: u64 = 0;
    for (page_ids, 1..) |page_id, position| {
        if (last.get(page_id)) |previous| {
            const active = fenwick.prefix(position - 1);
            const before_or_at_previous = fenwick.prefix(previous);
            const reuse_distance = active - before_or_at_previous;
            if (reuse_distance >= capacity_pages) misses += 1;
            fenwick.add(previous, -1);
        } else {
            misses += 1;
        }
        try last.put(page_id, position);
        fenwick.add(position, 1);
    }

    const n: f64 = @floatFromInt(page_ids.len);
    const p = @as(f64, @floatFromInt(misses)) / n;
    const z = 1.959963984540054;
    const denominator = 1.0 + z * z / n;
    const center = (p + z * z / (2.0 * n)) / denominator;
    const half = z * @sqrt((p * (1.0 - p) / n) +
        (z * z / (4.0 * n * n))) / denominator;
    return .{
        .accesses = page_ids.len,
        .misses = misses,
        .miss_rate = p,
        .lower95 = @max(0.0, center - half),
        .upper95 = @min(1.0, center + half),
    };
}

test "reuse distance produces an exact LRU miss count" {
    const trace = [_]u64{ 1, 2, 1, 3, 1, 2 };
    const one_page = try atCapacity(std.testing.allocator, &trace, 1);
    try std.testing.expectEqual(@as(u64, 6), one_page.misses);
    const two_pages = try atCapacity(std.testing.allocator, &trace, 2);
    try std.testing.expectEqual(@as(u64, 4), two_pages.misses);
}

test "confidence interval narrows with repeated evidence" {
    var trace: [20_000]u64 = undefined;
    for (&trace, 0..) |*page, index| page.* = index % 100;
    const point = try atCapacity(std.testing.allocator, &trace, 99);
    try std.testing.expect(point.relativeHalfWidth() < 0.05);
}

test "trace parser accepts normalized page identifiers" {
    const pages = try parseTrace(std.testing.allocator, "# page ids\n1\n0x2\n1\n");
    defer std.testing.allocator.free(pages);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 1 }, pages);
}

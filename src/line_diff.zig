//! 行级 Myers diff 算法（O(ND)）。
//!
//! 职责（§2.4）：给定两行序列，计算最短编辑脚本。纯函数，无 git 语义。
//! 返回 owned DiffOp 切片，调用方负责释放。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Op = enum { equal, delete, insert };

pub const DiffOp = struct {
    op: Op,
    a_idx: ?usize, // 0-based index into old (equal/delete); null for insert
    b_idx: ?usize, // 0-based index into new (equal/insert); null for delete
};

/// 计算两行序列的最短编辑脚本。
/// `a` = old 行，`b` = new 行，按字节相等比较。
/// 返回 owned 切片，调用方用 `allocator` 释放。
pub fn diff(allocator: Allocator, a: []const []const u8, b: []const []const u8) Allocator.Error![]DiffOp {
    const n: i64 = @intCast(a.len);
    const m: i64 = @intCast(b.len);
    if (n == 0 and m == 0) return &.{};

    const max_d: usize = @intCast(n + m);
    const offset: i64 = @intCast(max_d);
    const v_len: usize = 2 * max_d + 1;

    var v = try allocator.alloc(i64, v_len);
    defer allocator.free(v);
    @memset(v, 0);

    var trace = try allocator.alloc([]i64, max_d + 1);
    var trace_count: usize = 0;
    defer {
        for (trace[0..trace_count]) |t| allocator.free(t);
        allocator.free(trace);
    }

    var d: usize = 0;
    while (d <= max_d) : (d += 1) {
        trace[d] = try allocator.alloc(i64, v_len);
        trace_count += 1;
        @memcpy(trace[d], v);

        const d_i: i64 = @intCast(d);
        var k: i64 = -d_i;
        while (k <= d_i) : (k += 2) {
            const ki: usize = @intCast(k + offset);

            var x: i64 = if (k == -d_i or (k != d_i and v[ki - 1] < v[ki + 1]))
                v[ki + 1]
            else
                v[ki - 1] + 1;

            var y: i64 = x - k;
            while (x < n and y < m and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[ki] = x;

            if (x >= n and y >= m) {
                return backtrack(allocator, trace, d, offset, n, m);
            }
        }
    }
    unreachable; // Myers 保证 d <= n+m 时到达终点
}

fn backtrack(
    allocator: Allocator,
    trace: []const []i64,
    d: usize,
    offset: i64,
    n: i64,
    m: i64,
) Allocator.Error![]DiffOp {
    var ops = std.ArrayList(DiffOp).empty;
    errdefer ops.deinit(allocator);

    var x: i64 = n;
    var y: i64 = m;

    var step: usize = d;
    while (step > 0) : (step -= 1) {
        const v = trace[step];
        const k: i64 = x - y;
        const ki: usize = @intCast(k + offset);

        const is_insert = if (k == -@as(i64, @intCast(step)))
            true
        else if (k == @as(i64, @intCast(step)))
            false
        else
            v[ki - 1] < v[ki + 1];

        const prev_k: i64 = if (is_insert) k + 1 else k - 1;
        const prev_ki: usize = @intCast(prev_k + offset);
        const start_x: i64 = if (is_insert) v[prev_ki] else v[prev_ki] + 1;

        while (x > start_x) {
            x -= 1;
            y -= 1;
            try ops.append(allocator, .{ .op = .equal, .a_idx = @intCast(x), .b_idx = @intCast(y) });
        }

        if (is_insert) {
            y -= 1;
            try ops.append(allocator, .{ .op = .insert, .a_idx = null, .b_idx = @intCast(y) });
        } else {
            x -= 1;
            try ops.append(allocator, .{ .op = .delete, .a_idx = @intCast(x), .b_idx = null });
        }
    }

    while (x > 0 and y > 0) {
        x -= 1;
        y -= 1;
        try ops.append(allocator, .{ .op = .equal, .a_idx = @intCast(x), .b_idx = @intCast(y) });
    }

    std.mem.reverse(DiffOp, ops.items);
    return ops.toOwnedSlice(allocator);
}

/// 将文本按 `\n` 切分。返回切片指向 `text` 内部，外层数组需用 `allocator` 释放。
/// 末尾无换行时最后一行仍计入；空文本返回空切片。
/// 每行末尾的 `\r` 会被剥离以兼容 CRLF。
pub fn splitLines(allocator: Allocator, text: []const u8) Allocator.Error![][]const u8 {
    if (text.len == 0) return &.{};
    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(allocator);
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            var end = i;
            if (end > start and text[end - 1] == '\r') end -= 1;
            try lines.append(allocator, text[start..end]);
            start = i + 1;
        }
    }
    if (start < text.len) {
        var end = text.len;
        if (end > start and text[end - 1] == '\r') end -= 1;
        try lines.append(allocator, text[start..end]);
    }
    return lines.toOwnedSlice(allocator);
}

const testing = std.testing;

fn checkOps(ops: []const DiffOp, expected: []const struct { op: Op, a: ?usize, b: ?usize }) !void {
    try testing.expectEqual(expected.len, ops.len);
    for (ops, expected) |got, want| {
        try testing.expectEqual(want.op, got.op);
        try testing.expectEqual(want.a, got.a_idx);
        try testing.expectEqual(want.b, got.b_idx);
    }
}

test "diff identical" {
    const a = [_][]const u8{ "a", "b", "c" };
    const ops = try diff(testing.allocator, &a, &a);
    defer testing.allocator.free(ops);
    try checkOps(ops, &.{
        .{ .op = .equal, .a = 0, .b = 0 },
        .{ .op = .equal, .a = 1, .b = 1 },
        .{ .op = .equal, .a = 2, .b = 2 },
    });
}

test "diff all inserted" {
    const a = [_][]const u8{};
    const b = [_][]const u8{ "x", "y" };
    const ops = try diff(testing.allocator, &a, &b);
    defer testing.allocator.free(ops);
    try checkOps(ops, &.{
        .{ .op = .insert, .a = null, .b = 0 },
        .{ .op = .insert, .a = null, .b = 1 },
    });
}

test "diff all deleted" {
    const a = [_][]const u8{ "x", "y" };
    const b = [_][]const u8{};
    const ops = try diff(testing.allocator, &a, &b);
    defer testing.allocator.free(ops);
    try checkOps(ops, &.{
        .{ .op = .delete, .a = 0, .b = null },
        .{ .op = .delete, .a = 1, .b = null },
    });
}

test "diff both empty" {
    const ops = try diff(testing.allocator, &.{}, &.{});
    defer testing.allocator.free(ops);
    try testing.expectEqual(@as(usize, 0), ops.len);
}

test "diff single line same" {
    const a = [_][]const u8{"x"};
    const ops = try diff(testing.allocator, &a, &a);
    defer testing.allocator.free(ops);
    try checkOps(ops, &.{.{ .op = .equal, .a = 0, .b = 0 }});
}

test "diff single line different" {
    const a = [_][]const u8{"x"};
    const b = [_][]const u8{"y"};
    const ops = try diff(testing.allocator, &a, &b);
    defer testing.allocator.free(ops);
    try checkOps(ops, &.{
        .{ .op = .delete, .a = 0, .b = null },
        .{ .op = .insert, .a = null, .b = 0 },
    });
}

test "diff mixed: keep, delete, insert" {
    const a = [_][]const u8{ "a", "b", "c", "d" };
    const b = [_][]const u8{ "a", "c", "e", "d" };
    const ops = try diff(testing.allocator, &a, &b);
    defer testing.allocator.free(ops);
    // a kept, b deleted, c kept, e inserted, d kept
    try checkOps(ops, &.{
        .{ .op = .equal, .a = 0, .b = 0 },
        .{ .op = .delete, .a = 1, .b = null },
        .{ .op = .equal, .a = 2, .b = 1 },
        .{ .op = .insert, .a = null, .b = 2 },
        .{ .op = .equal, .a = 3, .b = 3 },
    });
}

test "diff swap two lines" {
    const a = [_][]const u8{ "a", "b" };
    const b = [_][]const u8{ "b", "a" };
    const ops = try diff(testing.allocator, &a, &b);
    defer testing.allocator.free(ops);
    // delete a[0]="a", keep a[1]="b"==b[0], insert b[1]="a"
    try checkOps(ops, &.{
        .{ .op = .delete, .a = 0, .b = null },
        .{ .op = .equal, .a = 1, .b = 0 },
        .{ .op = .insert, .a = null, .b = 1 },
    });
}

test "diff no common lines" {
    const a = [_][]const u8{"x"};
    const b = [_][]const u8{ "y", "z" };
    const ops = try diff(testing.allocator, &a, &b);
    defer testing.allocator.free(ops);
    try checkOps(ops, &.{
        .{ .op = .delete, .a = 0, .b = null },
        .{ .op = .insert, .a = null, .b = 0 },
        .{ .op = .insert, .a = null, .b = 1 },
    });
}

test "splitLines empty text" {
    const lines = try splitLines(testing.allocator, "");
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 0), lines.len);
}

test "splitLines trailing newline" {
    const lines = try splitLines(testing.allocator, "a\nb\n");
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("a", lines[0]);
    try testing.expectEqualStrings("b", lines[1]);
}

test "splitLines no trailing newline" {
    const lines = try splitLines(testing.allocator, "x\ny");
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("x", lines[0]);
    try testing.expectEqualStrings("y", lines[1]);
}

test "splitLines empty line in middle" {
    const lines = try splitLines(testing.allocator, "a\n\nb\n");
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("", lines[1]);
}

test "splitLines CRLF: '\\r' stays in line content" {
    // CRLF line endings: \r\n should be treated as line separator,
    // but splitLines only splits on \n, leaving \r at end of each line.
    const lines = try splitLines(testing.allocator, "a\r\nb\r\n");
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 2), lines.len);
    // BUG: \r is left in the line content
    try testing.expectEqualStrings("a", lines[0]);
    try testing.expectEqualStrings("b", lines[1]);
}

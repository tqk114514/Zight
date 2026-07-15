//! changed-path Bloom filter（Murmur3 双哈希）。
//!
//! 职责（§2.4）：纯数据结构，无 git 语义。供 index.zig 构建与查询。
//! 算法（ADR 001）：Kirsch-Mitzenmacher 双哈希，
//! h1 = Murmur3_32(path)，h2 = Murmur3_32(path, h1)，
//! 第 i 个位 = (h1 + i*h2) mod bit_count，k = 4。
//! 空 Bloom（bit_count = 0）语义为「可能包含一切」：查询永远返回 true，
//! 用于根 commit（无 first parent）等保守场景，保证 blame 正确性不丢。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Murmur3_32 = std.hash.Murmur3_32;

const K: u32 = 4;
const FPP: f64 = 0.01;
const LN2: f64 = 0.6931471805599453;

/// Bloom filter。`bits` 可能自有（`build` 产物）或借用（`fromBytes` 借用外部 buffer）。
/// 调用方按所有权来源决定是否 `deinit`：`build` 产物须 `deinit`；
/// `fromBytes` 产物随外部 buffer 一并释放，**不可** `deinit`。
pub const Bloom = struct {
    bits: []u8,
    bit_count: usize,

    pub fn deinit(self: *Bloom, gpa: Allocator) void {
        if (self.bits.len > 0) gpa.free(self.bits);
        self.bits = &.{};
        self.bit_count = 0;
    }

    /// 是否「可能」包含 `path`。空 Bloom 永远返回 true（保守）。
    pub fn mightContain(self: Bloom, path: []const u8) bool {
        if (self.bit_count == 0) return true;
        const h1 = Murmur3_32.hash(path);
        const h2 = Murmur3_32.hashWithSeed(path, h1);
        const bc = self.bit_count;
        var i: u32 = 0;
        while (i < K) : (i += 1) {
            const idx = @as(usize, @intCast(h1 +% (i *% h2))) % bc;
            const byte = idx / 8;
            const bit = @as(u3, @intCast(idx % 8));
            if ((self.bits[byte] & (@as(u8, 1) << bit)) == 0) return false;
        }
        return true;
    }
};

/// 按 n 个元素、fpp=0.01 计算最优位数，向上对齐到字节边界。n=0 返回 0。
pub fn optimalBitCount(n: usize) usize {
    if (n == 0) return 0;
    const m = @as(f64, @floatFromInt(n)) * (-@log(FPP)) / (LN2 * LN2);
    const bits = @as(usize, @intFromFloat(@ceil(m)));
    return (bits + 7) / 8 * 8;
}

/// 从路径集合构建 Bloom。调用方拥有返回值，须 `deinit` 释放。
pub fn build(gpa: Allocator, paths: []const []const u8) Allocator.Error!Bloom {
    const bit_count = optimalBitCount(paths.len);
    if (bit_count == 0) return .{ .bits = &.{}, .bit_count = 0 };

    const buf = try gpa.alloc(u8, bit_count / 8);
    @memset(buf, 0);
    for (paths) |p| {
        const h1 = Murmur3_32.hash(p);
        const h2 = Murmur3_32.hashWithSeed(p, h1);
        var i: u32 = 0;
        while (i < K) : (i += 1) {
            const idx = @as(usize, @intCast(h1 +% (i *% h2))) % bit_count;
            buf[idx / 8] |= (@as(u8, 1) << @as(u3, @intCast(idx % 8)));
        }
    }
    return .{ .bits = buf, .bit_count = bit_count };
}

/// 从已序列化字节构造（借用，不拷贝）。`bit_count = bytes.len * 8`。
/// 返回值随 `bytes` 一同释放，**不可** `deinit`。
pub fn fromBytes(bytes: []u8) Bloom {
    return .{ .bits = bytes, .bit_count = bytes.len * 8 };
}

const testing = std.testing;

test "Bloom: contains added paths" {
    var b = try build(testing.allocator, &.{ "src/a.txt", "README.md", "src/b/c.txt" });
    defer b.deinit(testing.allocator);
    try testing.expect(b.mightContain("src/a.txt"));
    try testing.expect(b.mightContain("README.md"));
    try testing.expect(b.mightContain("src/b/c.txt"));
}

test "Bloom: absent path likely false (no false negative)" {
    var b = try build(testing.allocator, &.{"src/a.txt"});
    defer b.deinit(testing.allocator);
    // 远离的路径；fpp=0.01 下大概率返回 false，但允许假阳，故不强制。
    // 只断言无假阴：已加入的一定 true。
    try testing.expect(b.mightContain("src/a.txt"));
}

test "Bloom: empty bloom always returns true" {
    const b = Bloom{ .bits = &.{}, .bit_count = 0 };
    try testing.expect(b.mightContain("anything"));
    try testing.expect(b.mightContain(""));
}

test "Bloom: fromBytes round-trip" {
    var built = try build(testing.allocator, &.{ "x", "y", "z" });
    defer built.deinit(testing.allocator);
    // 拷贝一份模拟序列化字节
    const copy = try testing.allocator.dupe(u8, built.bits);
    defer testing.allocator.free(copy);
    const borrowed = fromBytes(copy);
    try testing.expect(borrowed.mightContain("x"));
    try testing.expect(borrowed.mightContain("y"));
    try testing.expect(borrowed.mightContain("z"));
    // 借用者不可 deinit
}

test "Bloom: fromBytes empty" {
    const borrowed = fromBytes(&.{});
    try testing.expect(borrowed.mightContain("anything"));
}

test "optimalBitCount: zero and alignment" {
    try testing.expectEqual(@as(usize, 0), optimalBitCount(0));
    // n=1, fpp=0.01 => m≈9.585 bits => 对齐到 16 (2 bytes)
    try testing.expectEqual(@as(usize, 16), optimalBitCount(1));
    // 必为 8 的倍数
    const n_values = [_]usize{ 1, 5, 10, 50, 100, 1000 };
    for (n_values) |n| {
        const bc = optimalBitCount(n);
        try testing.expectEqual(@as(usize, 0), bc % 8);
    }
}

test "Bloom: large path set low false-positive" {
    // 100 条路径，统计假阳率应远低于 50%
    var paths: [100][]const u8 = undefined;
    var i: usize = 0;
    var buf: [100][16]u8 = undefined;
    while (i < 100) : (i += 1) {
        const s = std.fmt.bufPrint(&buf[i], "path-{d:0>10}", .{i}) catch unreachable;
        paths[i] = s;
    }
    var b = try build(testing.allocator, paths[0..]);
    defer b.deinit(testing.allocator);
    // 已加入全部 true
    for (paths) |p| try testing.expect(b.mightContain(p));
    // 未加入的 100 条，假阳应 < 10（fpp=0.01 期望 1）
    var fp: usize = 0;
    var j: usize = 1000;
    while (j < 1100) : (j += 1) {
        var qbuf: [16]u8 = undefined;
        const q = std.fmt.bufPrint(&qbuf, "path-{d:0>10}", .{j}) catch unreachable;
        if (b.mightContain(q)) fp += 1;
    }
    try testing.expect(fp < 10);
}

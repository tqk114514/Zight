//! SHA-1 / SHA-256 哈希封装。
//!
//! 封装 `std.crypto.Sha1` 与 `std.crypto.sha2.Sha256`。v1 默认 SHA-1；
//! SHA-256 仅在 `Hash` 枚举预留入口，实现可推迟（§4.1）。

const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// 哈希算法。v1 仅实现 `.sha1`；`.sha256` 为预留入口（§4.1）。
pub const Hash = enum {
    sha1,
    sha256,

    pub fn digestLen(h: Hash) usize {
        return switch (h) {
            .sha1 => Sha1.digest_length,
            .sha256 => Sha256.digest_length,
        };
    }
};

/// 对象 ID（SHA-1，20 字节）。
///
/// 内存中以原始字节存放；与文件名 / hex 文本互转通过 `fromHex` / `toHex`。
pub const Oid = struct {
    bytes: [Sha1.digest_length]u8,

    /// 从 40 字符 hex 解析。非法 hex 返回 `error.InvalidHex`。
    pub fn fromHex(hex: []const u8) error{InvalidHex}!Oid {
        if (hex.len != Sha1.digest_length * 2) return error.InvalidHex;
        var out: Oid = .{ .bytes = undefined };
        _ = std.fmt.hexToBytes(&out.bytes, hex) catch return error.InvalidHex;
        return out;
    }

    /// 写入 40 字符小写 hex。`out` 必须 40 字节。
    pub fn toHex(self: Oid, out: []u8) void {
        std.debug.assert(out.len == Sha1.digest_length * 2);
        const hex = std.fmt.bytesToHex(&self.bytes, .lower);
        @memcpy(out, &hex);
    }

    /// 分配一个新的 41 字节（40 + NUL）hex 字符串。调用方拥有内存。
    pub fn toHexAlloc(self: Oid, gpa: std.mem.Allocator) error{OutOfMemory}![:0]u8 {
        const hex = std.fmt.bytesToHex(&self.bytes, .lower);
        return gpa.dupeZ(u8, &hex) catch return error.OutOfMemory;
    }

    pub fn eql(a: Oid, b: Oid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn isZero(self: Oid) bool {
        return std.mem.allEqual(u8, &self.bytes, 0);
    }
};

/// 计算 `data` 的 SHA-1，写入 `out`。
pub fn sha1(data: []const u8, out: *[Sha1.digest_length]u8) void {
    Sha1.hash(data, out, .{});
}

/// 增量 SHA-1 计算器。
pub const Sha1Hasher = struct {
    inner: Sha1,

    pub fn init() Sha1Hasher {
        return .{ .inner = Sha1.init(.{}) };
    }

    pub fn update(self: *Sha1Hasher, data: []const u8) void {
        self.inner.update(data);
    }

    pub fn final(self: *Sha1Hasher, out: *[Sha1.digest_length]u8) void {
        self.inner.final(out);
    }
};

/// 计算 `data` 的 SHA-256，写入 `out`。
pub fn sha256(data: []const u8, out: *[Sha256.digest_length]u8) void {
    Sha256.hash(data, out, .{});
}

test "Oid.fromHex happy" {
    const oid = try Oid.fromHex("0fc4067fabcaf5bd623d95558059a71c84ed3490");
    var hex: [40]u8 = undefined;
    oid.toHex(&hex);
    try std.testing.expectEqualStrings("0fc4067fabcaf5bd623d95558059a71c84ed3490", &hex);
}

test "Oid.fromHex error: wrong length" {
    try std.testing.expectError(error.InvalidHex, Oid.fromHex("ab"));
    try std.testing.expectError(error.InvalidHex, Oid.fromHex("0fc4067fabcaf5bd623d95558059a71c84ed3490ff"));
}

test "Oid.fromHex error: non-hex char" {
    try std.testing.expectError(error.InvalidHex, Oid.fromHex("zzc4067fabcaf5bd623d95558059a71c84ed3490"));
}

test "Oid.eql and isZero" {
    const a = try Oid.fromHex("0000000000000000000000000000000000000000");
    try std.testing.expect(a.isZero());
    const b = try Oid.fromHex("0fc4067fabcaf5bd623d95558059a71c84ed3490");
    try std.testing.expect(!b.isZero());
    try std.testing.expect(!Oid.eql(a, b));
    try std.testing.expect(Oid.eql(b, b));
}

test "sha1 known vector" {
    var digest: [20]u8 = undefined;
    sha1("hello", &digest);
    var hex: [40]u8 = undefined;
    const hex_arr = std.fmt.bytesToHex(&digest, .lower);
    @memcpy(&hex, &hex_arr);
    try std.testing.expectEqualStrings("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d", &hex);
}

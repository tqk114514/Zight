//! zlib 压缩 / 解压封装。
//!
//! 封装 `std.compress.flate`（§3.1）。git loose 对象与 packfile 均使用 zlib
//! (RFC 1950) 容器包裹 deflate 流。解压大小受 `limit` 约束（§5.2）。

const std = @import("std");
const flate = std.compress.flate;

pub const ZlibError = error{
    BadZlibHeader,
    WrongZlibChecksum,
    InvalidDeflate,
    OutOfMemory,
    StreamTooLong,
};

/// 解压一个完整的 zlib 流。
///
/// `compressed` 必须是完整的 zlib 容器（含 2 字节头与 4 字节 adler32 尾）。
/// 解压后字节数受 `limit` 约束，超出返回 `error.StreamTooLong`（§5.2）。
/// 调用方拥有返回内存，需用同一 allocator 释放。
pub fn decompress(
    gpa: std.mem.Allocator,
    compressed: []const u8,
    limit: std.Io.Limit,
) ZlibError![]u8 {
    var src = std.Io.Reader.fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&src, .zlib, &window);
    const out = dec.reader.allocRemaining(gpa, limit) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        error.ReadFailed => mapErr(dec.err),
    };
    errdefer gpa.free(out);
    if (dec.err) |e| return mapErr(e);
    // std.compress.flate 只读取尾部 adler32 但不校验，手动比对以满足 §4.3 对象完整性
    var hasher: std.hash.Adler32 = .{};
    hasher.update(out);
    if (hasher.adler != dec.container_metadata.zlib.adler) return error.WrongZlibChecksum;
    return out;
}

fn mapErr(err_opt: ?flate.Decompress.Error) ZlibError {
    const e = err_opt orelse return error.InvalidDeflate;
    return switch (e) {
        error.BadZlibHeader => error.BadZlibHeader,
        error.WrongZlibChecksum => error.WrongZlibChecksum,
        else => error.InvalidDeflate,
    };
}

test "decompress empty zlib stream" {
    // 0x01 = final stored block（final=1, kind=00）；LEN=0, NLEN=0xffff；adler32 of "" = 1
    const empty_zlib = [_]u8{ 0x78, 0x9c, 0x01, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01 };
    const out = try decompress(std.testing.allocator, &empty_zlib, .unlimited);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "decompress bad zlib header" {
    const bad = [_]u8{ 0xff, 0xff, 0x03, 0x00 };
    try std.testing.expectError(error.BadZlibHeader, decompress(std.testing.allocator, &bad, .unlimited));
}

fn openZlibFixture() !@import("repo.zig").Repo {
    const io = std.Io.Threaded.global_single_threaded.io();
    return @import("repo.zig").Repo.open(io, std.testing.allocator, "test/fixtures/tiny");
}

fn readmeBlobOid() !@import("hash.zig").Oid {
    const content = "hello zight\n";
    var header_buf: [32]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "blob {d}\x00", .{content.len});
    var hasher = @import("hash.zig").Sha1Hasher.init();
    hasher.update(header);
    hasher.update(content);
    var oid: @import("hash.zig").Oid = .{ .bytes = undefined };
    hasher.final(&oid.bytes);
    return oid;
}

test "decompress wrong checksum" {
    // 真实非空 zlib 流（tiny fixture 的 README blob），翻转末位 adler 字节
    var repo = try openZlibFixture();
    defer repo.close();
    const oid = try readmeBlobOid();
    var path_buf: [64]u8 = undefined;
    const obj_path = try @import("object.zig").loosePath(&path_buf, oid);
    const compressed = try repo.readGitFileUnlimited(obj_path);
    defer std.testing.allocator.free(compressed);

    var corrupted = try std.testing.allocator.dupe(u8, compressed);
    defer std.testing.allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 0xff;
    try std.testing.expectError(error.WrongZlibChecksum, decompress(std.testing.allocator, corrupted, .unlimited));
}

test "decompress StreamTooLong on limit" {
    const empty_zlib = [_]u8{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01 };
    try std.testing.expectError(error.StreamTooLong, decompress(std.testing.allocator, &empty_zlib, .limited(0)));
}

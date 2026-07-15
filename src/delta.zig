//! OFS_DELTA / REF_DELTA 解压。
//!
//! 职责（§2.4）：将 delta 指令流应用到 base 对象，得到 target 对象。
//! 纯函数，不负责查找 base 对象或递归 delta 链（由 reader.zig 协调）。
//!
//! delta 指令格式：
//! - header: source_size (varint) + target_size (varint)
//! - copy (MSB=1): bits 0-3 标记 offset 字节，bits 4-6 标记 size 字节；size=0 表示 0x10000
//! - insert (MSB=0): 低 7 位为字面量长度（1-127，0 保留）

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DeltaError = error{
    MalformedDelta,
    DeltaSizeMismatch,
    OutOfMemory,
    LimitExceeded,
};

/// 将 delta 指令流 `delta` 应用到 `base`，得到 target。
///
/// 调用方拥有返回内存。`max_target_size` 约束 target 大小（§5.2 防止恶意 packfile OOM）。
/// delta 链递归与深度上限 50（§5.2）由 reader.zig 负责。
pub fn applyDelta(
    allocator: Allocator,
    base: []const u8,
    delta: []const u8,
    max_target_size: usize,
) DeltaError![]u8 {
    var pos: usize = 0;
    const source_size = try readVarInt(delta, &pos);
    if (source_size != base.len) return error.MalformedDelta;
    const target_size = try readVarInt(delta, &pos);
    if (target_size > max_target_size) return error.LimitExceeded;

    const target = allocator.alloc(u8, @intCast(target_size)) catch return error.OutOfMemory;
    errdefer allocator.free(target);

    var out: usize = 0;
    while (pos < delta.len) {
        const op = delta[pos];
        pos += 1;
        if (op & 0x80 != 0) {
            var offset: u32 = 0;
            var size: u32 = 0;
            if (op & 0x01 != 0) offset |= try readByte(delta, &pos);
            if (op & 0x02 != 0) offset |= @as(u32, try readByte(delta, &pos)) << 8;
            if (op & 0x04 != 0) offset |= @as(u32, try readByte(delta, &pos)) << 16;
            if (op & 0x08 != 0) offset |= @as(u32, try readByte(delta, &pos)) << 24;
            if (op & 0x10 != 0) size |= try readByte(delta, &pos);
            if (op & 0x20 != 0) size |= @as(u32, try readByte(delta, &pos)) << 8;
            if (op & 0x40 != 0) size |= @as(u32, try readByte(delta, &pos)) << 16;
            if (size == 0) size = 0x10000;
            const off: usize = offset;
            const sz: usize = size;
            if (off > base.len or sz > base.len - off) return error.MalformedDelta;
            if (out + sz > target.len) return error.MalformedDelta;
            @memcpy(target[out..][0..sz], base[off..][0..sz]);
            out += sz;
        } else {
            const len: usize = op & 0x7f;
            if (len == 0) return error.MalformedDelta;
            if (pos + len > delta.len) return error.MalformedDelta;
            if (out + len > target.len) return error.MalformedDelta;
            @memcpy(target[out..][0..len], delta[pos..][0..len]);
            out += len;
            pos += len;
        }
    }

    if (out != target_size) return error.DeltaSizeMismatch;
    return target;
}

fn readVarInt(delta: []const u8, pos: *usize) DeltaError!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= delta.len) return error.MalformedDelta;
        const c = delta[pos.*];
        pos.* += 1;
        result |= @as(u64, c & 0x7f) << shift;
        if (c & 0x80 == 0) break;
        if (shift > 56) return error.MalformedDelta;
        shift += 7;
    }
    return result;
}

fn readByte(delta: []const u8, pos: *usize) DeltaError!u8 {
    if (pos.* >= delta.len) return error.MalformedDelta;
    const b = delta[pos.*];
    pos.* += 1;
    return b;
}

const testing = std.testing;

/// 将 varint 编码后追加到 `list`。
fn appendVarInt(list: *std.ArrayList(u8), value: u64) !void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) {
            byte |= 0x80;
            try list.append(testing.allocator, byte);
        } else {
            try list.append(testing.allocator, byte);
            break;
        }
    }
}

/// 追加 copy 指令到 `list`：从 `offset` 复制 `size` 字节。
fn appendCopyOp(list: *std.ArrayList(u8), offset: u32, size: u32) !void {
    var op: u8 = 0x80;
    var buf: [7]u8 = undefined;
    var n: usize = 0;
    if (offset & 0xff != 0) { op |= 0x01; buf[n] = @intCast(offset & 0xff); n += 1; }
    if (offset & 0xff00 != 0) { op |= 0x02; buf[n] = @intCast((offset >> 8) & 0xff); n += 1; }
    if (offset & 0xff0000 != 0) { op |= 0x04; buf[n] = @intCast((offset >> 16) & 0xff); n += 1; }
    if (offset & 0xff000000 != 0) { op |= 0x08; buf[n] = @intCast((offset >> 24) & 0xff); n += 1; }
    if (size & 0xff != 0) { op |= 0x10; buf[n] = @intCast(size & 0xff); n += 1; }
    if (size & 0xff00 != 0) { op |= 0x20; buf[n] = @intCast((size >> 8) & 0xff); n += 1; }
    if (size & 0xff0000 != 0) { op |= 0x40; buf[n] = @intCast((size >> 16) & 0xff); n += 1; }
    try list.append(testing.allocator, op);
    try list.appendSlice(testing.allocator, buf[0..n]);
}

/// 追加 insert 指令到 `list`：插入字面量 `data`（长度 1-127）。
fn appendInsertOp(list: *std.ArrayList(u8), data: []const u8) !void {
    try testing.expect(data.len > 0 and data.len <= 127);
    try list.append(testing.allocator, @intCast(data.len));
    try list.appendSlice(testing.allocator, data);
}

/// 组装完整 delta 字节流。调用方拥有返回内存。
fn buildDelta(source_size: u64, target_size: u64, instructions: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(testing.allocator);
    try appendVarInt(&list, source_size);
    try appendVarInt(&list, target_size);
    try list.appendSlice(testing.allocator, instructions);
    return list.toOwnedSlice(testing.allocator);
}

test "applyDelta copy and insert" {
    const base = "Hello, World!";
    var instr: std.ArrayList(u8) = .empty;
    defer instr.deinit(testing.allocator);
    try appendCopyOp(&instr, 0, 7); // "Hello, "
    try appendInsertOp(&instr, "Zight ");
    try appendCopyOp(&instr, 7, 6); // "World!"

    const delta = try buildDelta(13, 19, instr.items);
    defer testing.allocator.free(delta);

    const result = try applyDelta(testing.allocator, base, delta, 1024);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello, Zight World!", result);
}

test "applyDelta pure copy" {
    const base = "abcdefghij";
    var instr: std.ArrayList(u8) = .empty;
    defer instr.deinit(testing.allocator);
    try appendCopyOp(&instr, 2, 5);

    const delta = try buildDelta(10, 5, instr.items);
    defer testing.allocator.free(delta);

    const result = try applyDelta(testing.allocator, base, delta, 1024);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("cdefg", result);
}

test "applyDelta pure insert" {
    var instr: std.ArrayList(u8) = .empty;
    defer instr.deinit(testing.allocator);
    try appendInsertOp(&instr, "hello");

    const delta = try buildDelta(0, 5, instr.items);
    defer testing.allocator.free(delta);

    const result = try applyDelta(testing.allocator, "", delta, 1024);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "applyDelta empty target" {
    const delta = try buildDelta(4, 0, &.{});
    defer testing.allocator.free(delta);

    const result = try applyDelta(testing.allocator, "base", delta, 1024);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "applyDelta size=0 means 0x10000" {
    var base_buf: [0x10000]u8 = undefined;
    for (&base_buf, 0..) |*b, i| b.* = @intCast(i & 0xff);
    var instr: std.ArrayList(u8) = .empty;
    defer instr.deinit(testing.allocator);
    try appendCopyOp(&instr, 0, 0); // size=0 → 0x10000

    const delta = try buildDelta(0x10000, 0x10000, instr.items);
    defer testing.allocator.free(delta);

    const result = try applyDelta(testing.allocator, &base_buf, delta, 0x10000);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &base_buf, result);
}

test "applyDelta multi-byte varint size" {
    var instr: std.ArrayList(u8) = .empty;
    defer instr.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        try appendInsertOp(&instr, "x");
    }

    const delta = try buildDelta(0, 300, instr.items);
    defer testing.allocator.free(delta);

    const result = try applyDelta(testing.allocator, "", delta, 1024);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 300), result.len);
}

test "applyDelta source size mismatch" {
    const delta = try buildDelta(100, 0, &.{});
    defer testing.allocator.free(delta);
    try testing.expectError(error.MalformedDelta, applyDelta(testing.allocator, "short", delta, 1024));
}

test "applyDelta target exceeds limit" {
    const delta = try buildDelta(0, 999, &.{});
    defer testing.allocator.free(delta);
    try testing.expectError(error.LimitExceeded, applyDelta(testing.allocator, "", delta, 100));
}

test "applyDelta copy out of bounds" {
    var instr: std.ArrayList(u8) = .empty;
    defer instr.deinit(testing.allocator);
    try appendCopyOp(&instr, 0, 5); // base only 3 bytes

    const delta = try buildDelta(3, 5, instr.items);
    defer testing.allocator.free(delta);
    try testing.expectError(error.MalformedDelta, applyDelta(testing.allocator, "abc", delta, 1024));
}

test "applyDelta insert truncated" {
    // insert 5 bytes but only 2 follow
    const delta = try buildDelta(0, 5, &.{ 5, 'a', 'b' });
    defer testing.allocator.free(delta);
    try testing.expectError(error.MalformedDelta, applyDelta(testing.allocator, "", delta, 1024));
}

test "applyDelta reserved opcode 0x00" {
    const delta = try buildDelta(0, 1, &.{0x00});
    defer testing.allocator.free(delta);
    try testing.expectError(error.MalformedDelta, applyDelta(testing.allocator, "", delta, 1024));
}

test "applyDelta output size mismatch" {
    // header says target_size=5, but no instructions → out=0
    const delta = try buildDelta(3, 5, &.{});
    defer testing.allocator.free(delta);
    try testing.expectError(error.DeltaSizeMismatch, applyDelta(testing.allocator, "abc", delta, 1024));
}

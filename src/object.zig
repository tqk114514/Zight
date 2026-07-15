//! loose 对象读取：blob / tree / commit / tag。
//!
//! loose 对象位于 `.git/objects/xx/yyyy...`，zlib 压缩，解压后为
//! `<type> <size>\0<content>`（§4.1）。读取后必须重算 SHA-1 与文件名校验，
//! 不匹配返回 `CorruptedObject` 且不返回部分数据（§4.3）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("hash.zig");
const Oid = hash.Oid;
const zlib = @import("zlib.zig");
const Repo = @import("repo.zig").Repo;
const ZightError = @import("error.zig").ZightError;

pub const ObjectType = enum {
    blob,
    tree,
    commit,
    tag,

    pub fn fromBytes(s: []const u8) ?ObjectType {
        if (std.mem.eql(u8, s, "blob")) return .blob;
        if (std.mem.eql(u8, s, "tree")) return .tree;
        if (std.mem.eql(u8, s, "commit")) return .commit;
        if (std.mem.eql(u8, s, "tag")) return .tag;
        return null;
    }
};

/// 读取到的 loose 对象。
///
/// `buf` 拥有完整解压数据（header + content）；`content` 是其中 content 部分。
/// 调用方用 `deinit` 释放 `buf`。content 不需要单独释放。
pub const Object = struct {
    type: ObjectType,
    buf: []u8,
    content: []u8,

    pub fn deinit(self: *Object, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
        self.buf = &.{};
        self.content = &.{};
    }
};

/// 读取并校验 loose 对象。
///
/// 路径：`objects/<2hex>/<38hex>`。解压大小受 `limits.loose_object_max` 约束（§5.2）。
/// 解压后重算 SHA-1，与 `oid` 不匹配返回 `error.CorruptedObject`。
pub fn readLoose(repo: *Repo, allocator: Allocator, oid: Oid) ZightError!Object {
    var path_buf: [64]u8 = undefined;
    const path = try loosePath(&path_buf, oid);

    const compressed = repo.readGitFile(path, .limited(repo.limits.loose_object_max)) catch |err| switch (err) {
        error.NotFound => return error.NotFound,
        error.StreamTooLong => return error.LimitExceeded,
        else => |e| return e,
    };
    defer repo.allocator.free(compressed);

    const limit = std.Io.Limit.limited(repo.limits.loose_object_max);
    const decompressed = zlib.decompress(allocator, compressed, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.LimitExceeded,
        else => return error.CorruptedObject,
    };
    errdefer allocator.free(decompressed);

    var content: []u8 = undefined;
    const obj_type = try parseHeader(decompressed, &content);

    if (!verifyHash(decompressed, oid)) {
        allocator.free(decompressed);
        return error.CorruptedObject;
    }

    return .{
        .type = obj_type,
        .buf = decompressed,
        .content = content,
    };
}

/// 构造 loose 对象路径：`objects/xx/yyyy...`。返回指向 `buf` 内的切片。
pub fn loosePath(buf: *[64]u8, oid: Oid) error{InvalidPath}![]const u8 {
    var hex: [40]u8 = undefined;
    oid.toHex(&hex);
    const result = std.fmt.bufPrint(buf, "objects/{s}/{s}", .{ hex[0..2], hex[2..] }) catch return error.InvalidPath;
    return result;
}

/// 解析 `<type> <size>\0` 头部，`content` 指向 `\0` 之后的内容。
fn parseHeader(buf: []u8, content: *[]u8) ZightError!ObjectType {
    const space = std.mem.indexOfScalar(u8, buf, ' ') orelse return error.MalformedObject;
    const nul = std.mem.indexOfScalarPos(u8, buf, space + 1, 0) orelse return error.MalformedObject;

    const obj_type = ObjectType.fromBytes(buf[0..space]) orelse return error.MalformedObject;
    const size_str = buf[space + 1 .. nul];
    const declared_size = std.fmt.parseInt(usize, size_str, 10) catch return error.MalformedObject;

    const body = buf[nul + 1 ..];
    if (body.len != declared_size) return error.CorruptedObject;

    content.* = body;
    return obj_type;
}

fn verifyHash(buf: []const u8, oid: Oid) bool {
    var digest: [20]u8 = undefined;
    hash.sha1(buf, &digest);
    return std.mem.eql(u8, &digest, &oid.bytes);
}

const testing = std.testing;

fn openFixture(name: []const u8) !Repo {
    const path = try std.fmt.allocPrint(testing.allocator, "test/fixtures/{s}", .{name});
    defer testing.allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    return Repo.open(io, testing.allocator, path);
}

fn headOid(repo: *Repo) !Oid {
    const head = try repo.readGitFileUnlimited("HEAD");
    defer testing.allocator.free(head);
    const trimmed = std.mem.trimEnd(u8, head, " \t\r\n");
    const ref_name = trimmed["ref: ".len..];
    const oid_hex = try repo.readGitFileUnlimited(ref_name);
    defer testing.allocator.free(oid_hex);
    const t = std.mem.trimEnd(u8, oid_hex, " \t\r\n");
    return Oid.fromHex(t) catch error.MalformedRef;
}

test "readLoose HEAD commit" {
    var repo = try openFixture("tiny");
    defer repo.close();
    const oid = try headOid(&repo);
    var obj = try readLoose(&repo, testing.allocator, oid);
    defer obj.deinit(testing.allocator);
    try std.testing.expectEqual(ObjectType.commit, obj.type);
    try std.testing.expect(std.mem.startsWith(u8, obj.content, "tree "));
}

test "readLoose missing returns NotFound" {
    var repo = try openFixture("tiny");
    defer repo.close();
    const oid = Oid.fromHex("0000000000000000000000000000000000000000") catch unreachable;
    try std.testing.expectError(error.NotFound, readLoose(&repo, testing.allocator, oid));
}

test "readLoose returns LimitExceeded when compressed file exceeds limit" {
    // rule.md §5.2: 超限返回 LimitExceeded。readLoose 用 .limited(loose_object_max)
    // 读取压缩文件，超限时 readGitFile 透传 StreamTooLong，未映射为 LimitExceeded。
    var repo = try openFixture("tiny");
    defer repo.close();
    repo.limits.loose_object_max = 10;
    const oid = try headOid(&repo);
    try std.testing.expectError(error.LimitExceeded, readLoose(&repo, testing.allocator, oid));
}

test "loosePath format" {
    var buf: [64]u8 = undefined;
    const oid = Oid.fromHex("0fc4067fabcaf5bd623d95558059a71c84ed3490") catch unreachable;
    const p = try loosePath(&buf, oid);
    try std.testing.expectEqualStrings("objects/0f/c4067fabcaf5bd623d95558059a71c84ed3490", p);
}

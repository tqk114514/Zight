//! ref / packed-refs / HEAD 解析（§4.2）。
//!
//! 支持 loose refs（`.git/refs/...`）、packed-refs（含 `^{}` peeled 标记）、
//! HEAD（symbolic 与 detached）。symref 链深度上限 5，超出返回 `SymrefTooDeep`。

const std = @import("std");

const Oid = @import("hash.zig").Oid;
const Repo = @import("repo.zig").Repo;
const path = @import("path.zig");
const ZightError = @import("error.zig").ZightError;

const SYMREF_PREFIX = "ref: ";
const MAX_SYMREF_DEPTH: u32 = 5;

/// ref 解析结果。`symref` 分支拥有其缓冲，调用方需 `deinit` 释放。
pub const Ref = union(enum) {
    /// 直接指向一个对象。
    oid: Oid,
    /// symbolic ref，指向另一个 ref 名（如 `refs/heads/main`）。拥有该切片。
    symref: []u8,

    pub fn deinit(self: *Ref, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .oid => {},
            .symref => |s| gpa.free(s),
        }
    }
};

/// 读取单个 ref（loose 优先，回退 packed-refs）。
///
/// 返回 `null` 表示 ref 不存在。`name` 形如 `refs/heads/main` 或 `HEAD`。
/// 返回的 `Ref` 由调用方拥有，需 `deinit` 释放（`.oid` 分支为 no-op）。
pub fn readRef(repo: *Repo, name: []const u8) ZightError!?Ref {
    path.validateRefName(name) catch return error.MalformedRef;

    if (try readLooseRef(repo, name)) |loose| return loose;
    if (try findInPackedRefs(repo, name)) |found_oid| return .{ .oid = found_oid };
    return null;
}

/// 解析 ref 到最终 OID，跟随 symref 链（深度上限 5）。
pub fn resolveRef(repo: *Repo, name: []const u8) ZightError!Oid {
    var current = name;
    var depth: u32 = 0;
    var prev_ref: ?Ref = null;
    defer if (prev_ref) |*r| r.deinit(repo.allocator);

    while (true) {
        depth += 1;
        if (depth > MAX_SYMREF_DEPTH) return error.SymrefTooDeep;

        var ref = (try readRef(repo, current)) orelse return error.NotFound;
        switch (ref) {
            .oid => |o| {
                ref.deinit(repo.allocator);
                return o;
            },
            .symref => |target| {
                if (prev_ref) |*r| r.deinit(repo.allocator);
                prev_ref = ref;
                current = target;
            },
        }
    }
}

/// 解析 HEAD 到最终 OID（跟随 symref 链）。
pub fn resolveHead(repo: *Repo) ZightError!Oid {
    return resolveRef(repo, "HEAD");
}

fn readLooseRef(repo: *Repo, name: []const u8) ZightError!?Ref {
    const content = repo.readGitFileUnlimited(name) catch |err| switch (err) {
        error.NotFound => return null,
        else => |e| return e,
    };
    defer repo.allocator.free(content);

    const trimmed = std.mem.trimEnd(u8, content, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, SYMREF_PREFIX)) {
        const target = trimmed[SYMREF_PREFIX.len..];
        if (target.len == 0) return error.MalformedRef;
        const owned = repo.allocator.dupe(u8, target) catch return error.OutOfMemory;
        return Ref{ .symref = owned };
    }

    const oid = Oid.fromHex(trimmed) catch return error.MalformedRef;
    return .{ .oid = oid };
}

/// 在 packed-refs 中按名查找。返回 null 表示未找到。
fn findInPackedRefs(repo: *Repo, name: []const u8) ZightError!?Oid {
    const data = repo.readGitFileUnlimited("packed-refs") catch |err| switch (err) {
        error.NotFound => return null,
        else => |e| return e,
    };
    defer repo.allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const oid_hex = line[0..space];
        const ref_name = line[space + 1 ..];
        if (!std.mem.eql(u8, ref_name, name)) continue;
        const oid = Oid.fromHex(oid_hex) catch return error.MalformedRef;
        return oid;
    }
    return null;
}

const testing = std.testing;

fn openFixture(name: []const u8) !Repo {
    const fixture_path = try std.fmt.allocPrint(testing.allocator, "test/fixtures/{s}", .{name});
    defer testing.allocator.free(fixture_path);
    const io = std.Io.Threaded.global_single_threaded.io();
    return Repo.open(io, testing.allocator, fixture_path);
}

test "resolveHead tiny fixture" {
    var repo = try openFixture("tiny");
    defer repo.close();
    const oid = try resolveHead(&repo);
    try std.testing.expect(!oid.isZero());
}

test "readRef nonexistent returns null" {
    var repo = try openFixture("tiny");
    defer repo.close();
    const r = try readRef(&repo, "refs/heads/nonexistent");
    try std.testing.expect(r == null);
}

test "resolveRef missing returns NotFound" {
    var repo = try openFixture("tiny");
    defer repo.close();
    try std.testing.expectError(error.NotFound, resolveRef(&repo, "refs/heads/ghost"));
}

test "readRef rejects malformed name" {
    var repo = try openFixture("tiny");
    defer repo.close();
    try std.testing.expectError(error.MalformedRef, readRef(&repo, "../etc/passwd"));
}

test "resolveRef deep symref chain returns SymrefTooDeep" {
    var repo = try openFixture("edge");
    defer repo.close();
    try std.testing.expectError(error.SymrefTooDeep, resolveRef(&repo, "refs/chain/a"));
}

test "packed-refs lookup via merge fixture" {
    var repo = try openFixture("merge");
    defer repo.close();
    const r = try readRef(&repo, "refs/heads/main");
    try std.testing.expect(r != null);
    try std.testing.expect(r.? == .oid);
}

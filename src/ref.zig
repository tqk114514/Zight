//! ref / packed-refs / HEAD 解析（§4.2）。
//!
//! 支持 loose refs（`.git/refs/...`）、packed-refs（含 `^{}` peeled 标记）、
//! HEAD（symbolic 与 detached）。symref 链深度上限 5，超出返回 `SymrefTooDeep`。

const std = @import("std");
const Allocator = std.mem.Allocator;

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
        var ref = (try readRef(repo, current)) orelse return error.NotFound;
        switch (ref) {
            .oid => |o| {
                ref.deinit(repo.allocator);
                return o;
            },
            .symref => |target| {
                depth += 1;
                if (depth > MAX_SYMREF_DEPTH) {
                    ref.deinit(repo.allocator);
                    return error.SymrefTooDeep;
                }
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

/// 枚举所有 ref 的最终 tip oid（loose refs + packed-refs + HEAD），去重升序。
/// 用于索引失效检测（ADR 001）：拼接后 SHA-1 即得 `ref_tips_digest`。
/// 调用方拥有返回切片。无任何 ref 时返回空切片。
pub fn collectTips(repo: *Repo, allocator: Allocator) ZightError![]Oid {
    var set = std.AutoHashMap([20]u8, void).init(allocator);
    defer set.deinit();

    try addTip(repo, &set, "HEAD");
    try walkLooseRefs(repo, allocator, "refs", &set);
    try collectPackedTips(repo, &set);

    var list = std.ArrayList(Oid).empty;
    defer list.deinit(allocator);
    var it = set.keyIterator();
    while (it.next()) |k| {
        list.append(allocator, .{ .bytes = k.* }) catch return error.OutOfMemory;
    }
    std.mem.sort(Oid, list.items, {}, oidLessThan);
    return list.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn addTip(repo: *Repo, set: *std.AutoHashMap([20]u8, void), name: []const u8) ZightError!void {
    if (resolveRef(repo, name)) |oid| {
        set.put(oid.bytes, {}) catch return error.OutOfMemory;
    } else |_| {}
}

fn oidLessThan(_: void, a: Oid, b: Oid) bool {
    return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
}

/// 递归遍历 `.git/<prefix>` 下的 loose ref 文件，解析为 tip oid 加入 `set`。
fn walkLooseRefs(repo: *Repo, allocator: Allocator, prefix: []const u8, set: *std.AutoHashMap([20]u8, void)) ZightError!void {
    var dir = repo.git_dir.openDir(repo.io, prefix, .{ .iterate = true, .access_sub_paths = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        else => return error.IoFailed,
    };
    defer dir.close(repo.io);

    var it = dir.iterate();
    while (it.next(repo.io)) |entry_opt| {
        const entry = entry_opt orelse break;
        const child = std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name }) catch return error.OutOfMemory;
        defer allocator.free(child);
        switch (entry.kind) {
            .directory => try walkLooseRefs(repo, allocator, child, set),
            .file => try addTip(repo, set, child),
            else => {},
        }
    } else |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        else => return error.IoFailed,
    }
}

/// 解析 packed-refs 中所有 ref 名，解析为 tip oid 加入 `set`。
fn collectPackedTips(repo: *Repo, set: *std.AutoHashMap([20]u8, void)) ZightError!void {
    const data = repo.readGitFileUnlimited("packed-refs") catch |err| switch (err) {
        error.NotFound => return,
        else => |e| return e,
    };
    defer repo.allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        try addTip(repo, set, line[space + 1 ..]);
    }
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

test "resolveRef: 5-layer symref chain resolves (boundary)" {
    // rule.md §4.2: symref 链最大深度 5。5 层 symref + oid 应放行。
    // 当前实现 depth 在 readRef 前递增，5 层 symref 需 6 次 readRef，
    // depth=6 > MAX_SYMREF_DEPTH(5) 被误拒为 SymrefTooDeep。
    var repo = try openFixture("edge");
    defer repo.close();
    const oid = try resolveRef(&repo, "refs/chain5/a");
    try std.testing.expect(!oid.isZero());
}

test "packed-refs lookup via merge fixture" {
    var repo = try openFixture("merge");
    defer repo.close();
    const r = try readRef(&repo, "refs/heads/main");
    try std.testing.expect(r != null);
    try std.testing.expect(r.? == .oid);
}

test "collectTips: tiny has HEAD tip" {
    var repo = try openFixture("tiny");
    defer repo.close();
    const tips = try collectTips(&repo, testing.allocator);
    defer testing.allocator.free(tips);
    try testing.expect(tips.len >= 1);
    const head = try resolveHead(&repo);
    var found = false;
    for (tips) |t| if (std.mem.eql(u8, &t.bytes, &head.bytes)) {
        found = true;
        break;
    };
    try testing.expect(found);
    // 升序
    for (tips[1..], tips[0 .. tips.len - 1]) |b, a| {
        try testing.expect(std.mem.order(u8, &a.bytes, &b.bytes) != .gt);
    }
}

test "collectTips: merge dedups shared tips" {
    var repo = try openFixture("merge");
    defer repo.close();
    const tips = try collectTips(&repo, testing.allocator);
    defer testing.allocator.free(tips);
    // merge fixture: main, branchB, branchC 都指向各自最新 commit；至少 1 个
    try testing.expect(tips.len >= 1);
    // 无重复（去重）
    var i: usize = 0;
    while (i + 1 < tips.len) : (i += 1) {
        try testing.expect(!std.mem.eql(u8, &tips[i].bytes, &tips[i + 1].bytes));
    }
}

test "collectTips: empty repo returns empty slice" {
    var repo = try openFixture("empty");
    defer repo.close();
    const tips = try collectTips(&repo, testing.allocator);
    defer testing.allocator.free(tips);
    try testing.expectEqual(@as(usize, 0), tips.len);
}

//! high-level 共享读取层：loose + pack fallback + delta 链递归解析。
//!
//! 职责（§2.4）：给调用方提供统一的 `readObject(allocator, oid) -> Object` 接口，
//! 内部先查 loose（object.zig），再查所有 packfile（pack.zig），
//! 对 delta 对象递归解析 base 并应用 delta（delta.zig）。
//! delta 链深度上限由 `Limits.delta_depth_max` 约束（§5.2）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("hash.zig");
const Oid = hash.Oid;
const object = @import("object.zig");
const Object = object.Object;
const ObjectType = object.ObjectType;
const pack_mod = @import("pack.zig");
const Pack = pack_mod.Pack;
const PackObjectType = pack_mod.PackObjectType;
const PackError = pack_mod.PackError;
const delta = @import("delta.zig");
const Repo = @import("repo.zig").Repo;
const ZightError = @import("error.zig").ZightError;

const CachedObj = struct {
    type: ObjectType,
    data: []u8,
};

/// 对象缓存。两层：
/// - `by_oid`：oid → 对象，覆盖 loose + pack 顶层读取（未 gc 仓库也命中）
/// - `by_offset`：(pack_idx, offset) → 对象，覆盖 pack delta 链中间对象（oid 未知）
/// `allocator` 应为不 reset 的 arena。调用方须 `deinit` 释放。
pub const ObjectCache = struct {
    by_oid: std.AutoHashMap([20]u8, CachedObj),
    by_offset: []std.AutoHashMap(u64, CachedObj),
    allocator: Allocator,

    pub fn init(allocator: Allocator, pack_count: usize) ZightError!ObjectCache {
        const maps = allocator.alloc(std.AutoHashMap(u64, CachedObj), pack_count) catch return error.OutOfMemory;
        for (maps) |*m| m.* = .init(allocator);
        return .{ .by_oid = .init(allocator), .by_offset = maps, .allocator = allocator };
    }

    pub fn deinit(self: *ObjectCache) void {
        var it = self.by_oid.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.data);
        self.by_oid.deinit();
        for (self.by_offset) |*m| {
            var mit = m.iterator();
            while (mit.next()) |e| self.allocator.free(e.value_ptr.data);
            m.deinit();
        }
        self.allocator.free(self.by_offset);
    }

    pub fn getOid(self: *ObjectCache, oid: Oid) ?CachedObj {
        return self.by_oid.get(oid.bytes);
    }

    pub fn putOid(self: *ObjectCache, oid: Oid, obj: CachedObj) ZightError!void {
        self.by_oid.put(oid.bytes, obj) catch return error.OutOfMemory;
    }

    pub fn getOffset(self: *ObjectCache, pk_idx: usize, offset: u64) ?CachedObj {
        return self.by_offset[pk_idx].get(offset);
    }

    pub fn putOffset(self: *ObjectCache, pk_idx: usize, offset: u64, obj: CachedObj) ZightError!void {
        self.by_offset[pk_idx].put(offset, obj) catch return error.OutOfMemory;
    }
};

fn storeOid(c: *ObjectCache, oid: Oid, obj_type: ObjectType, data: []const u8) void {
    const dup = c.allocator.dupe(u8, data) catch return;
    c.putOid(oid, .{ .type = obj_type, .data = dup }) catch {
        c.allocator.free(dup);
    };
}

fn storeOffset(c: *ObjectCache, pk_idx: usize, offset: u64, obj_type: ObjectType, data: []const u8) void {
    const dup = c.allocator.dupe(u8, data) catch return;
    c.putOffset(pk_idx, offset, .{ .type = obj_type, .data = dup }) catch {
        c.allocator.free(dup);
    };
}

/// 仓库对象读取器。持有所有 packfile 句柄，调用方须 `close` 释放。
pub const Reader = struct {
    repo: *Repo,
    packs: []Pack,
    ocache: ?*ObjectCache = null,

    /// 打开 `repo` 下所有 packfile。无 pack 目录时返回空 packs。
    pub fn open(repo: *Repo) ZightError!Reader {
        var packs: std.ArrayList(Pack) = .empty;
        errdefer {
            for (packs.items) |*p| p.close();
            packs.deinit(repo.allocator);
        }

        if (repo.git_dir.openDir(repo.io, "objects/pack", .{ .access_sub_paths = false, .iterate = true })) |pack_dir| {
            defer pack_dir.close(repo.io);
            var it = pack_dir.iterate();
            while (it.next(repo.io)) |entry_opt| {
                const entry = entry_opt orelse break;
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
                const name = entry.name[0 .. entry.name.len - 4];
                if (Pack.open(repo, name)) |p| {
                    packs.append(repo.allocator, p) catch return error.OutOfMemory;
                } else |err| switch (err) {
                    error.NotFound => continue,
                    else => return mapPackError(err),
                }
            } else |err| switch (err) {
                error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
                else => return error.IoFailed,
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return error.IoFailed,
        }

        return .{
            .repo = repo,
            .packs = try packs.toOwnedSlice(repo.allocator),
        };
    }

    pub fn close(self: *Reader) void {
        for (self.packs) |*p| p.close();
        self.repo.allocator.free(self.packs);
    }

    /// 读取 `oid` 对应的对象。先查 pack，再查 loose。
    /// `allocator` 决定返回 `Object.buf` 的分配，调用方须用同一 `allocator` 调 `deinit`。
    pub fn readObject(self: *Reader, allocator: Allocator, oid: Oid) ZightError!Object {
        return self.readObjectInternal(allocator, oid, 0);
    }

    fn readObjectInternal(self: *Reader, allocator: Allocator, oid: Oid, depth: u32) ZightError!Object {
        if (self.ocache) |c| {
            if (c.getOid(oid)) |cached| {
                const dup = allocator.dupe(u8, cached.data) catch return error.OutOfMemory;
                return .{ .type = cached.type, .buf = dup, .content = dup };
            }
        }

        for (self.packs, 0..) |*pk, i| {
            if (pk.findOffset(oid)) |offset| {
                return self.resolvePackObject(allocator, oid, i, offset, depth);
            }
        }

        const obj = object.readLoose(self.repo, allocator, oid) catch |err| switch (err) {
            error.NotFound => return error.NotFound,
            else => |e| return e,
        };
        if (self.ocache) |c| storeOid(c, oid, obj.type, obj.content);
        return obj;
    }

    /// `oid` 非 null 时为顶层读取，存 `by_oid`；为 null 时为 delta 链中间对象，存 `by_offset`。
    fn resolvePackObject(self: *Reader, allocator: Allocator, oid: ?Oid, pk_idx: usize, offset: u64, depth: u32) ZightError!Object {
        const pk = &self.packs[pk_idx];

        if (self.ocache) |c| {
            if (c.getOffset(pk_idx, offset)) |cached| {
                const dup = allocator.dupe(u8, cached.data) catch return error.OutOfMemory;
                return .{ .type = cached.type, .buf = dup, .content = dup };
            }
        }

        if (depth >= self.repo.limits.delta_depth_max) return error.LimitExceeded;

        var raw = pk.readRaw(allocator, offset) catch |err| return mapPackError(err);

        if (!raw.isDelta()) {
            const obj_type: ObjectType = switch (raw.type) {
                .commit => .commit,
                .tree => .tree,
                .blob => .blob,
                .tag => .tag,
                else => unreachable, // isDelta 已过滤 ofs_delta/ref_delta
            };
            if (self.ocache) |c| storeOffset(c, pk_idx, offset, obj_type, raw.data);
            if (oid) |o| if (self.ocache) |c| storeOid(c, o, obj_type, raw.data);
            return .{
                .type = obj_type,
                .buf = raw.data,
                .content = raw.data,
            };
        }

        defer allocator.free(raw.data);

        var base_obj: Object = if (raw.base_offset) |bo|
            try self.resolvePackObject(allocator, null, pk_idx, bo, depth + 1)
        else if (raw.base_oid) |boid|
            try self.readObjectInternal(allocator, boid, depth + 1)
        else
            return error.MalformedObject;
        defer base_obj.deinit(allocator);

        const target = delta.applyDelta(
            allocator,
            base_obj.content,
            raw.data,
            self.repo.limits.packfile_object_max,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LimitExceeded => error.LimitExceeded,
            error.MalformedDelta => error.MalformedObject,
            error.DeltaSizeMismatch => error.CorruptedObject,
        };

        if (self.ocache) |c| storeOffset(c, pk_idx, offset, base_obj.type, target);
        if (oid) |o| if (self.ocache) |c| storeOid(c, o, base_obj.type, target);

        return .{
            .type = base_obj.type,
            .buf = target,
            .content = target,
        };
    }

    /// 是否存在 `oid` 对应的对象（loose 或 pack）。
    pub fn hasObject(self: *Reader, oid: Oid) bool {
        var path_buf: [64]u8 = undefined;
        const path = object.loosePath(&path_buf, oid) catch return false;
        _ = self.repo.git_dir.statFile(self.repo.io, path, .{}) catch {
            for (self.packs) |*pk| {
                if (pk.hasObject(oid)) return true;
            }
            return false;
        };
        return true;
    }

    /// 读取 commit 对象并解析其 `tree` 字段 oid。
    /// `commit_oid` 必须指向 commit 对象，否则返回 `MalformedObject`。
    pub fn commitTree(self: *Reader, allocator: Allocator, commit_oid: Oid) ZightError!Oid {
        var obj = try self.readObject(allocator, commit_oid);
        defer obj.deinit(allocator);
        if (obj.type != .commit) return error.MalformedObject;
        if (!std.mem.startsWith(u8, obj.content, "tree ")) return error.MalformedObject;
        const nl = std.mem.indexOfScalar(u8, obj.content, '\n') orelse return error.MalformedObject;
        return Oid.fromHex(obj.content[5..nl]) catch error.MalformedObject;
    }

    /// 读取 commit 对象并解析其首个 `parent` 字段 oid。
    /// 无 parent（根 commit）返回 `null`。
    pub fn firstParent(self: *Reader, allocator: Allocator, commit_oid: Oid) ZightError!?Oid {
        var obj = try self.readObject(allocator, commit_oid);
        defer obj.deinit(allocator);
        if (obj.type != .commit) return error.MalformedObject;
        var it = std.mem.splitScalar(u8, obj.content, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                return Oid.fromHex(line[7..]) catch error.MalformedObject;
            }
            if (line.len == 0) break;
        }
        return null;
    }

    /// 读取 commit 对象并一次性解析 tree oid + 全部 parents + committer time。
    /// `parents` 由调用方拥有，须 `deinit` 释放。比分别 `commitTree`+`firstParent`
    /// 少一次 commit 读取。
    pub fn commitMeta(self: *Reader, allocator: Allocator, commit_oid: Oid) ZightError!CommitMeta {
        var obj = try self.readObject(allocator, commit_oid);
        defer obj.deinit(allocator);
        if (obj.type != .commit) return error.MalformedObject;
        return parseCommitMeta(allocator, obj.content);
    }

    /// 将 `oid` peel 到 commit。若已是 commit 直接返回；若为 tag 对象，
    /// 跟随其 `object` 字段直到到达 commit。tag 嵌套深度上限 10。
    pub fn peelToCommit(self: *Reader, allocator: Allocator, oid: Oid) ZightError!Oid {
        var current = oid;
        var depth: u32 = 0;
        while (depth < 10) : (depth += 1) {
            var obj = try self.readObject(allocator, current);
            defer obj.deinit(allocator);
            switch (obj.type) {
                .commit => return current,
                .tag => {
                    if (!std.mem.startsWith(u8, obj.content, "object ")) return error.MalformedObject;
                    const nl = std.mem.indexOfScalar(u8, obj.content, '\n') orelse return error.MalformedObject;
                    current = Oid.fromHex(obj.content[7..nl]) catch return error.MalformedObject;
                },
                else => return error.MalformedObject,
            }
        }
        return error.LimitExceeded;
    }
};

/// commit 元数据（一次解析所得）。`parents` 由调用方拥有。
pub const CommitMeta = struct {
    tree: Oid,
    parents: []Oid,
    committer_time: i64,

    pub fn deinit(self: *CommitMeta, gpa: Allocator) void {
        gpa.free(self.parents);
        self.parents = &.{};
    }
};

/// 解析 commit 内容头部：`tree`、所有 `parent`、`committer` time。
fn parseCommitMeta(allocator: Allocator, content: []const u8) ZightError!CommitMeta {
    var parents: std.ArrayList(Oid) = .empty;
    errdefer parents.deinit(allocator);

    var tree: Oid = Oid{ .bytes = undefined };
    var have_tree = false;
    var committer_time: i64 = 0;
    var have_committer = false;

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "tree ")) {
            tree = Oid.fromHex(line[5..]) catch return error.MalformedObject;
            have_tree = true;
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            parents.append(allocator, Oid.fromHex(line[7..]) catch return error.MalformedObject) catch return error.OutOfMemory;
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            committer_time = parseCommitterTime(line) catch return error.MalformedObject;
            have_committer = true;
        }
    }

    if (!have_tree or !have_committer) return error.MalformedObject;
    return .{
        .tree = tree,
        .parents = try parents.toOwnedSlice(allocator),
        .committer_time = committer_time,
    };
}

/// 从 `committer` 行末尾提取 unix 时间戳（倒数第二个 token，跳过时区）。
fn parseCommitterTime(line: []const u8) ZightError!i64 {
    var it = std.mem.splitBackwardsScalar(u8, line, ' ');
    _ = it.first(); // tz
    const ts_str = it.next() orelse return error.MalformedObject;
    return std.fmt.parseInt(i64, ts_str, 10) catch return error.MalformedObject;
}

fn mapPackError(err: PackError) ZightError {
    return switch (err) {
        error.NotFound => error.NotFound,
        error.OutOfMemory => error.OutOfMemory,
        error.LimitExceeded => error.LimitExceeded,
        error.IoFailed => error.IoFailed,
        error.AccessDenied => error.AccessDenied,
        error.MalformedPack, error.MalformedIdx, error.WrongPackVersion, error.WrongIdxVersion => error.MalformedObject,
        error.CorruptedPack, error.CorruptedIdx => error.CorruptedObject,
    };
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

test "Reader.readObject loose commit" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const oid = try headOid(&repo);
    var obj = try reader.readObject(testing.allocator, oid);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.commit, obj.type);
    try testing.expect(std.mem.startsWith(u8, obj.content, "tree "));
}

test "Reader.readObject packed commit" {
    var repo = try openFixture("packed");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const oid = try headOid(&repo);
    var obj = try reader.readObject(testing.allocator, oid);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.commit, obj.type);
    try testing.expect(std.mem.startsWith(u8, obj.content, "tree "));
}

test "Reader.readObject all packed objects (OFS_DELTA)" {
    var repo = try openFixture("packed");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    try testing.expect(reader.packs.len > 0);
    const pk = &reader.packs[0];
    var i: usize = 0;
    while (i < pk.count) : (i += 1) {
        var sha: [20]u8 = undefined;
        @memcpy(&sha, pk.idx.shas[i * 20 ..][0..20]);
        const oid = Oid{ .bytes = sha };
        var obj = try reader.readObject(testing.allocator, oid);
        defer obj.deinit(testing.allocator);
        try testing.expect(obj.content.len > 0 or obj.type == .blob);
    }
}

test "Reader.readObject all packed-ref objects (REF_DELTA)" {
    var repo = try openFixture("packed-ref");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    try testing.expect(reader.packs.len > 0);
    const pk = &reader.packs[0];
    var i: usize = 0;
    while (i < pk.count) : (i += 1) {
        var sha: [20]u8 = undefined;
        @memcpy(&sha, pk.idx.shas[i * 20 ..][0..20]);
        const oid = Oid{ .bytes = sha };
        var obj = try reader.readObject(testing.allocator, oid);
        defer obj.deinit(testing.allocator);
        try testing.expect(obj.content.len > 0 or obj.type == .blob);
    }
}

test "Reader.readObject missing returns NotFound" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const zero = Oid.fromHex("0000000000000000000000000000000000000000") catch unreachable;
    try testing.expectError(error.NotFound, reader.readObject(testing.allocator, zero));
}

test "Reader.open empty fixture (no packs)" {
    var repo = try openFixture("empty");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    try testing.expectEqual(@as(usize, 0), reader.packs.len);
}

test "Reader.hasObject" {
    var repo = try openFixture("packed");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const oid = try headOid(&repo);
    try testing.expect(reader.hasObject(oid));

    const zero = Oid.fromHex("0000000000000000000000000000000000000000") catch unreachable;
    try testing.expect(!reader.hasObject(zero));
}

test "Reader.commitTree and firstParent" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const tip = try headOid(&repo);
    const tree = try reader.commitTree(testing.allocator, tip);
    var all_zero = true;
    for (tree.bytes) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try testing.expect(!all_zero);

    const parent = (try reader.firstParent(testing.allocator, tip)).?;
    const root_parent = try reader.firstParent(testing.allocator, parent);
    try testing.expect(root_parent == null);
}

test "Reader.commitTree rejects non-commit" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const tip = try headOid(&repo);
    const tree = try reader.commitTree(testing.allocator, tip);
    try testing.expectError(error.MalformedObject, reader.commitTree(testing.allocator, tree));
}

test "Reader.peelToCommit: annotated tag peels to commit" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const tag_hex = try repo.readGitFileUnlimited("refs/tags/v1.0");
    defer testing.allocator.free(tag_hex);
    const trimmed = std.mem.trimEnd(u8, tag_hex, " \t\r\n");
    const tag_oid = try Oid.fromHex(trimmed);

    const commit_oid = try reader.peelToCommit(testing.allocator, tag_oid);
    const head = try headOid(&repo);
    try testing.expect(Oid.eql(commit_oid, head));
}

test "Reader.peelToCommit: commit returns itself" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const head = try headOid(&repo);
    const peeled = try reader.peelToCommit(testing.allocator, head);
    try testing.expect(Oid.eql(peeled, head));
}

test "parseCommitMeta: short tree line returns MalformedObject not panic" {
    const malformed = "tree abc\ncommitter a <a@a> 1 +0000\n\nmsg";
    try testing.expectError(error.MalformedObject, parseCommitMeta(testing.allocator, malformed));
}

test "parseCommitMeta: short parent line returns MalformedObject not panic" {
    const malformed = "tree 0000000000000000000000000000000000000000\nparent abc\ncommitter a <a@a> 1 +0000\n\nmsg";
    try testing.expectError(error.MalformedObject, parseCommitMeta(testing.allocator, malformed));
}

fn computeLooseOid(obj_type: []const u8, content: []const u8) Oid {
    var header_buf: [32]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} {d}\x00", .{ obj_type, content.len }) catch unreachable;
    var hasher = hash.Sha1Hasher.init();
    hasher.update(header);
    hasher.update(content);
    var oid: Oid = .{ .bytes = undefined };
    hasher.final(&oid.bytes);
    return oid;
}

test "commitTree: short tree content returns MalformedObject not panic" {
    var repo = try openFixture("malformed");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const oid = computeLooseOid("commit", "tree abc");
    try testing.expectError(error.MalformedObject, reader.commitTree(testing.allocator, oid));
}

test "firstParent: short parent line returns MalformedObject not panic" {
    var repo = try openFixture("malformed");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const oid = computeLooseOid("commit", "parent abc");
    try testing.expectError(error.MalformedObject, reader.firstParent(testing.allocator, oid));
}

test "peelToCommit: short tag object content returns MalformedObject not panic" {
    var repo = try openFixture("malformed");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const oid = computeLooseOid("tag", "object abc");
    try testing.expectError(error.MalformedObject, reader.peelToCommit(testing.allocator, oid));
}

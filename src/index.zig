//! Zight 持久化索引（§6.3，ADR 001）。
//!
//! 存储 `.zight/index`：每个可达 commit 的 tree_oid + parents + committer time
//! + changed-path Bloom filter（相对 first parent）。blame 借助 Bloom 跳过
//! 未修改目标路径的 commit 的 tree 读取。
//!
//! 失效检测：索引头存储所有 ref tip oid 的 SHA-1 digest，`open` 时与当前
//! ref tip 集合比对，不匹配返回 null（调用方可选 `build` 重建）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("hash.zig");
const Oid = hash.Oid;
const Sha1Hasher = hash.Sha1Hasher;
const Repo = @import("repo.zig").Repo;
const Reader = @import("reader.zig").Reader;
const ObjectCache = @import("reader.zig").ObjectCache;
const ref = @import("ref.zig");
const diff = @import("diff.zig");
const bloom_mod = @import("bloom.zig");
const Bloom = bloom_mod.Bloom;
const ZightError = @import("error.zig").ZightError;

const MAGIC = "ZIDX";
const VERSION: u16 = 1;
const HEADER_LEN: usize = 4 + 2 + 4 + 20;
const ZIGHT_DIR = ".zight";
const INDEX_PATH = ".zight/index";

/// 单条 commit 索引记录。`parents` 与 `bloom` 借用 `Index.buf`，随 `Index` 一同释放。
pub const CommitRecord = struct {
    oid: Oid,
    tree: Oid,
    committer_time: i64,
    parents: []const Oid,
    bloom: Bloom,
};

/// 已加载的索引。调用方须 `deinit` 释放。`buf` 拥有所有记录数据。
pub const Index = struct {
    buf: []u8,
    commits: []CommitRecord,
    by_oid: std.AutoHashMap([20]u8, usize),
    allocator: Allocator,

    pub fn deinit(self: *Index) void {
        self.by_oid.deinit();
        self.allocator.free(self.commits);
        self.allocator.free(self.buf);
    }

    pub fn lookup(self: *const Index, oid: Oid) ?*const CommitRecord {
        const idx = self.by_oid.get(oid.bytes) orelse return null;
        return &self.commits[idx];
    }

    pub fn firstParent(self: *const Index, oid: Oid) ?Oid {
        const rec = self.lookup(oid) orelse return null;
        if (rec.parents.len == 0) return null;
        return rec.parents[0];
    }

    pub fn bloomMightContain(self: *const Index, oid: Oid, path: []const u8) bool {
        const rec = self.lookup(oid) orelse return true;
        return rec.bloom.mightContain(path);
    }
};

const BuildEntry = struct {
    oid: Oid,
    tree: Oid,
    committer_time: i64,
    parents: []Oid,
    bloom: Bloom,
};

/// 构建并写入 `.zight/index`（§4.4 例外允许写 `.zight/`）。
pub fn build(reader: *Reader, repo: *Repo, allocator: Allocator) ZightError!void {
    const buf = try buildToBuffer(reader, repo, allocator);
    defer allocator.free(buf);
    try writeIndexFile(repo, buf);
}

/// 打开 `.zight/index`。文件不存在或 ref tip digest 不匹配返回 null。
pub fn open(repo: *Repo, allocator: Allocator) ZightError!?Index {
    const dir = repo.worktree_dir orelse repo.git_dir;

    var zight_dir = dir.openDir(repo.io, ZIGHT_DIR, .{ .access_sub_paths = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        else => return error.IoFailed,
    };
    defer zight_dir.close(repo.io);

    const buf = zight_dir.readFileAlloc(repo.io, "index", allocator, .limited(repo.limits.index_file_max)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        error.StreamTooLong => return error.LimitExceeded,
        else => return error.IoFailed,
    };
    errdefer allocator.free(buf);

    const expected_digest = try computeRefTipsDigest(repo, allocator);
    const result = try parseBuffer(allocator, buf, expected_digest);
    if (result == null) {
        allocator.free(buf);
        return null;
    }
    return result;
}

/// 构建索引并返回序列化字节。调用方拥有返回切片。
pub fn buildToBuffer(reader: *Reader, repo: *Repo, allocator: Allocator) ZightError![]u8 {
    const tips = try ref.collectTips(repo, allocator);
    defer allocator.free(tips);

    var digest: [20]u8 = undefined;
    {
        var hasher = Sha1Hasher.init();
        for (tips) |t| hasher.update(&t.bytes);
        hasher.final(&digest);
    }

    var entries: std.ArrayList(BuildEntry) = .empty;
    defer {
        for (entries.items) |*e| {
            allocator.free(e.parents);
            e.bloom.deinit(allocator);
        }
        entries.deinit(allocator);
    }

    var visited = std.AutoHashMap([20]u8, void).init(allocator);
    defer visited.deinit();

    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(allocator);

    for (tips) |t| {
        const commit_oid = try reader.peelToCommit(allocator, t);
        if (visited.contains(commit_oid.bytes)) continue;
        visited.put(commit_oid.bytes, {}) catch return error.OutOfMemory;
        stack.append(allocator, commit_oid) catch return error.OutOfMemory;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var cache_arena = std.heap.ArenaAllocator.init(allocator);
    defer cache_arena.deinit();

    var tree_cache = diff.TreeCache.init(cache_arena.allocator());
    defer tree_cache.deinit();

    var ocache = ObjectCache.init(cache_arena.allocator(), reader.packs.len) catch return error.OutOfMemory;
    defer ocache.deinit();
    reader.ocache = &ocache;
    defer reader.ocache = null;

    while (stack.items.len > 0) {
        const oid = stack.items[stack.items.len - 1];
        stack.items.len -= 1;

        const arena_alloc = arena.allocator();
        const meta = try reader.commitMeta(arena_alloc, oid);
        const parents = try allocator.dupe(Oid, meta.parents);
        errdefer allocator.free(parents);

        var bl: Bloom = if (parents.len > 0) blk: {
            const parent_tree = try reader.commitTree(arena_alloc, parents[0]);
            const paths = try collectChangedPaths(arena_alloc, reader, parent_tree, meta.tree, &tree_cache);
            break :blk try bloom_mod.build(allocator, paths);
        } else .{ .bits = &.{}, .bit_count = 0 };
        errdefer bl.deinit(allocator);

        for (parents) |p| {
            if (visited.contains(p.bytes)) continue;
            visited.put(p.bytes, {}) catch return error.OutOfMemory;
            stack.append(allocator, p) catch return error.OutOfMemory;
        }

        entries.append(allocator, .{
            .oid = oid,
            .tree = meta.tree,
            .committer_time = meta.committer_time,
            .parents = parents,
            .bloom = bl,
        }) catch return error.OutOfMemory;
        bl = .{ .bits = &.{}, .bit_count = 0 };

        _ = arena.reset(.free_all);
    }

    std.mem.sort(BuildEntry, entries.items, {}, buildEntryOidLessThan);
    return serializeBuffer(allocator, &digest, entries.items);
}

/// 解析序列化字节。magic/version 错误返回 `MalformedObject`，digest 不匹配返回 null。
/// 成功时 `buf` 所有权转移给返回的 `Index`。
pub fn parseBuffer(allocator: Allocator, buf: []u8, expected_digest: [20]u8) ZightError!?Index {
    if (buf.len < HEADER_LEN) return error.MalformedObject;
    if (!std.mem.eql(u8, buf[0..4], MAGIC)) return error.MalformedObject;
    const version = std.mem.readInt(u16, buf[4..6], .little);
    if (version != VERSION) return error.MalformedObject;
    const commit_count = std.mem.readInt(u32, buf[6..10], .little);

    var stored_digest: [20]u8 = undefined;
    @memcpy(&stored_digest, buf[10..30]);
    if (!std.mem.eql(u8, &stored_digest, &expected_digest)) return null;

    var commits = allocator.alloc(CommitRecord, commit_count) catch return error.OutOfMemory;
    errdefer allocator.free(commits);

    var by_oid = std.AutoHashMap([20]u8, usize).init(allocator);
    errdefer by_oid.deinit();

    var off: usize = HEADER_LEN;
    var i: usize = 0;
    while (i < commit_count) : (i += 1) {
        if (off + 20 + 20 + 8 + 1 > buf.len) return error.MalformedObject;
        var oid: Oid = undefined;
        @memcpy(&oid.bytes, buf[off..][0..20]);
        off += 20;
        var tree: Oid = undefined;
        @memcpy(&tree.bytes, buf[off..][0..20]);
        off += 20;
        const committer_time = std.mem.readInt(i64, buf[off..][0..8], .little);
        off += 8;
        const parent_count: usize = buf[off];
        off += 1;

        const parents_bytes_len = parent_count * 20;
        if (off + parents_bytes_len + 4 > buf.len) return error.MalformedObject;
        const parents = std.mem.bytesAsSlice(Oid, buf[off..][0..parents_bytes_len]);
        off += parents_bytes_len;

        const bloom_byte_len = std.mem.readInt(u32, buf[off..][0..4], .little);
        off += 4;
        if (off + bloom_byte_len > buf.len) return error.MalformedObject;
        const bloom_bytes = buf[off..][0..bloom_byte_len];
        off += bloom_byte_len;

        commits[i] = .{
            .oid = oid,
            .tree = tree,
            .committer_time = committer_time,
            .parents = parents,
            .bloom = bloom_mod.fromBytes(bloom_bytes),
        };
        by_oid.put(oid.bytes, i) catch return error.OutOfMemory;
    }

    return Index{
        .buf = buf,
        .commits = commits,
        .by_oid = by_oid,
        .allocator = allocator,
    };
}

fn computeRefTipsDigest(repo: *Repo, allocator: Allocator) ZightError![20]u8 {
    const tips = try ref.collectTips(repo, allocator);
    defer allocator.free(tips);
    var hasher = Sha1Hasher.init();
    for (tips) |t| hasher.update(&t.bytes);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn collectChangedPaths(allocator: Allocator, reader: *Reader, old_tree: Oid, new_tree: Oid, cache: ?*diff.TreeCache) ZightError![][]u8 {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var d = try diff.TreeDiff.open(reader, allocator, old_tree, new_tree, cache);
    defer d.close();
    while (try d.next()) |change| {
        const p = allocator.dupe(u8, change.path) catch return error.OutOfMemory;
        paths.append(allocator, p) catch {
            allocator.free(p);
            return error.OutOfMemory;
        };
    }
    return paths.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn buildEntryOidLessThan(_: void, a: BuildEntry, b: BuildEntry) bool {
    return std.mem.order(u8, &a.oid.bytes, &b.oid.bytes) == .lt;
}

fn serializeBuffer(allocator: Allocator, digest: *const [20]u8, entries: []const BuildEntry) ZightError![]u8 {
    var total: usize = HEADER_LEN;
    for (entries) |e| {
        if (e.parents.len > 255) return error.LimitExceeded;
        total += 20 + 20 + 8 + 1 + e.parents.len * 20 + 4 + e.bloom.bits.len;
    }

    const buf = allocator.alloc(u8, total) catch return error.OutOfMemory;
    var off: usize = 0;

    @memcpy(buf[off..][0..4], MAGIC);
    off += 4;
    std.mem.writeInt(u16, buf[off..][0..2], VERSION, .little);
    off += 2;
    std.mem.writeInt(u32, buf[off..][0..4], @intCast(entries.len), .little);
    off += 4;
    @memcpy(buf[off..][0..20], digest);
    off += 20;

    for (entries) |e| {
        @memcpy(buf[off..][0..20], &e.oid.bytes);
        off += 20;
        @memcpy(buf[off..][0..20], &e.tree.bytes);
        off += 20;
        std.mem.writeInt(i64, buf[off..][0..8], e.committer_time, .little);
        off += 8;
        buf[off] = @intCast(e.parents.len);
        off += 1;
        for (e.parents) |p| {
            @memcpy(buf[off..][0..20], &p.bytes);
            off += 20;
        }
        std.mem.writeInt(u32, buf[off..][0..4], @intCast(e.bloom.bits.len), .little);
        off += 4;
        if (e.bloom.bits.len > 0) {
            @memcpy(buf[off..][0..e.bloom.bits.len], e.bloom.bits);
            off += e.bloom.bits.len;
        }
    }

    return buf;
}

fn writeIndexFile(repo: *Repo, buf: []const u8) ZightError!void {
    const dir = repo.worktree_dir orelse repo.git_dir;
    dir.createDirPath(repo.io, ZIGHT_DIR) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        else => return error.IoFailed,
    };
    dir.writeFile(repo.io, .{ .sub_path = INDEX_PATH, .data = buf }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        else => return error.IoFailed,
    };
}

const testing = std.testing;

fn openFixture(name: []const u8) !Repo {
    const path = try std.fmt.allocPrint(testing.allocator, "test/fixtures/{s}", .{name});
    defer testing.allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    return Repo.open(io, testing.allocator, path);
}

fn removeZightDir(repo: *Repo) void {
    const dir = repo.worktree_dir orelse repo.git_dir;
    dir.deleteFile(repo.io, ".zight/index") catch {}; // 测试清理，忽略不存在
    dir.deleteDir(repo.io, ".zight") catch {};
}

test "buildToBuffer + parseBuffer round-trip" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    var idx = blk: {
        const buf = try buildToBuffer(&reader, &repo, testing.allocator);
        errdefer testing.allocator.free(buf);
        const digest = try computeRefTipsDigest(&repo, testing.allocator);
        break :blk (try parseBuffer(testing.allocator, buf, digest)).?;
    };
    defer idx.deinit();

    const head = try ref.resolveHead(&repo);
    const rec = idx.lookup(head).?;
    try testing.expect(!rec.tree.isZero());
    try testing.expect(rec.parents.len > 0);
    try testing.expect(rec.committer_time > 0);

    const fp = idx.firstParent(head).?;
    try testing.expect(!fp.isZero());

    try testing.expect(idx.bloomMightContain(head, "src/nested.txt"));
}

test "parseBuffer digest mismatch returns null" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    const buf = try buildToBuffer(&reader, &repo, testing.allocator);
    defer testing.allocator.free(buf);

    var wrong_digest: [20]u8 = undefined;
    @memset(&wrong_digest, 0xFF);
    const result = try parseBuffer(testing.allocator, buf, wrong_digest);
    try testing.expect(result == null);
}

test "parseBuffer bad magic returns MalformedObject" {
    const buf = try testing.allocator.alloc(u8, HEADER_LEN);
    defer testing.allocator.free(buf);
    @memset(buf, 0);

    var digest: [20]u8 = undefined;
    @memset(&digest, 0);
    try testing.expectError(error.MalformedObject, parseBuffer(testing.allocator, buf, digest));
}

test "open missing returns null" {
    var repo = try openFixture("tiny");
    defer repo.close();
    const result = try open(&repo, testing.allocator);
    try testing.expect(result == null);
}

test "build + open file round-trip" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var reader = try Reader.open(&repo);
    defer reader.close();

    defer removeZightDir(&repo);

    try build(&reader, &repo, testing.allocator);

    var idx = (try open(&repo, testing.allocator)).?;
    defer idx.deinit();

    const head = try ref.resolveHead(&repo);
    try testing.expect(idx.lookup(head) != null);
}

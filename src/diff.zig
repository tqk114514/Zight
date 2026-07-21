//! 文件级 tree diff + 行级 diff 便捷函数。
//!
//! 职责（§2.4）：给定两个 tree oid，按 tree 条目名归并比较。
//! 两个 tree 条目按名匹配，OID 相同直接跳过（含子树，不递归读取），
//! 只有 OID 不同的子树才递归。这使索引构建只读变更路径上的 tree，
//! 而非全量遍历。

const std = @import("std");
const Allocator = std.mem.Allocator;

const Oid = @import("hash.zig").Oid;
const Reader = @import("reader.zig").Reader;
const tree_browse = @import("tree_browse.zig");
const RawEntry = tree_browse.RawEntry;
const parseEntry = tree_browse.parseEntry;
const TreeMode = tree_browse.TreeMode;
const line_diff = @import("line_diff.zig");
const DiffOp = line_diff.DiffOp;
const ZightError = @import("error.zig").ZightError;

pub const ChangeKind = enum { added, deleted, modified };

/// 单条文件变更。`path` 指向 TreeDiff 内部缓冲，在下一次 `next` 前有效。
pub const FileChange = struct {
    kind: ChangeKind,
    path: []const u8,
    old_oid: ?Oid, // null for added
    new_oid: ?Oid, // null for deleted
};

/// tree 对象缓存。oid → 解压后内容。跨多次 TreeDiff 复用，避免重复 zlib 解压。
/// 调用方须 `deinit` 释放。
pub const TreeCache = struct {
    map: std.AutoHashMap([20]u8, CachedTree),
    allocator: Allocator,

    const CachedTree = struct {
        buf: []u8,
        content: []const u8,
    };

    pub fn init(allocator: Allocator) TreeCache {
        return .{ .map = .init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *TreeCache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.buf);
        self.map.deinit();
    }

    pub fn get(self: *TreeCache, oid: Oid) ?[]const u8 {
        return if (self.map.get(oid.bytes)) |c| c.content else null;
    }

    pub fn put(self: *TreeCache, oid: Oid, buf: []u8, content: []const u8) !void {
        try self.map.put(oid.bytes, .{ .buf = buf, .content = content });
    }
};

const DiffFrame = struct {
    old_content: ?[]const u8, // null = old 侧无此子树
    new_content: ?[]const u8, // null = new 侧无此子树
    old_buf: ?[]u8, // 拥有的内存（释放用）
    new_buf: ?[]u8,
    old_pos: usize,
    new_pos: usize,
    base_len: usize, // path 前缀在入栈时的长度
};

/// 两个 tree 的文件级 diff 迭代器。调用方须 `close` 释放。
pub const TreeDiff = struct {
    reader: *Reader,
    allocator: Allocator,
    cache: ?*TreeCache,
    stack: std.ArrayList(DiffFrame),
    path: std.ArrayList(u8),
    old_entry: ?RawEntry,
    new_entry: ?RawEntry,

    /// `old_tree` 为 null 表示全部新增；`new_tree` 为 null 表示全部删除。
    /// `cache` 非空时，tree 对象内容跨 TreeDiff 实例复用，避免重复 zlib 解压。
    pub fn open(reader: *Reader, allocator: Allocator, old_tree: ?Oid, new_tree: ?Oid, cache: ?*TreeCache) ZightError!TreeDiff {
        var d: TreeDiff = .{
            .reader = reader,
            .allocator = allocator,
            .cache = cache,
            .stack = .empty,
            .path = .empty,
            .old_entry = null,
            .new_entry = null,
        };
        errdefer d.close();
        try d.pushFrame(old_tree, new_tree, 0);
        return d;
    }

    pub fn close(self: *TreeDiff) void {
        for (self.stack.items) |*f| {
            if (f.old_buf) |b| self.allocator.free(b);
            if (f.new_buf) |b| self.allocator.free(b);
        }
        self.stack.deinit(self.allocator);
        self.path.deinit(self.allocator);
    }

    fn loadTree(self: *TreeDiff, oid: Oid, out_buf: *?[]u8, out_content: *?[]const u8) ZightError!void {
        if (self.cache) |c| {
            if (c.get(oid)) |cached| {
                out_content.* = cached;
                return;
            }
            var obj = try self.reader.readObject(c.allocator, oid);
            if (obj.type != .tree) {
                obj.deinit(c.allocator);
                return error.MalformedObject;
            }
            c.put(oid, obj.buf, obj.content) catch {
                obj.deinit(c.allocator);
                return error.OutOfMemory;
            };
            out_content.* = obj.content;
            obj.buf = &.{};
            obj.content = &.{};
            return;
        }
        var obj = try self.reader.readObject(self.allocator, oid);
        if (obj.type != .tree) {
            obj.deinit(self.allocator);
            return error.MalformedObject;
        }
        out_buf.* = obj.buf;
        out_content.* = obj.content;
        obj.buf = &.{};
        obj.content = &.{};
    }

    fn pushFrame(self: *TreeDiff, old_tree: ?Oid, new_tree: ?Oid, base_len: usize) ZightError!void {
        var old_buf: ?[]u8 = null;
        var new_buf: ?[]u8 = null;
        var old_content: ?[]const u8 = null;
        var new_content: ?[]const u8 = null;

        errdefer {
            if (old_buf) |b| self.allocator.free(b);
            if (new_buf) |b| self.allocator.free(b);
        }

        if (old_tree) |oid| try self.loadTree(oid, &old_buf, &old_content);
        if (new_tree) |oid| try self.loadTree(oid, &new_buf, &new_content);

        try self.stack.append(self.allocator, .{
            .old_content = old_content,
            .new_content = new_content,
            .old_buf = old_buf,
            .new_buf = new_buf,
            .old_pos = 0,
            .new_pos = 0,
            .base_len = base_len,
        });
    }

    /// 拉取下一条变更；无更多变更返回 `null`。
    pub fn next(self: *TreeDiff) ZightError!?FileChange {
        while (self.stack.items.len > 0) {
            const fi = self.stack.items.len - 1;
            const frame = &self.stack.items[fi];

            if (self.old_entry == null) {
                if (frame.old_content) |c| {
                    self.old_entry = parseEntry(c, &frame.old_pos);
                }
            }
            if (self.new_entry == null) {
                if (frame.new_content) |c| {
                    self.new_entry = parseEntry(c, &frame.new_pos);
                }
            }

            if (self.old_entry == null and self.new_entry == null) {
                if (frame.old_buf) |b| self.allocator.free(b);
                if (frame.new_buf) |b| self.allocator.free(b);
                self.path.shrinkRetainingCapacity(frame.base_len);
                _ = self.stack.pop();
                continue;
            }

            if (self.old_entry == null) {
                const e = self.new_entry.?;
                self.new_entry = null;
                if (e.mode == .directory) {
                    try self.appendDirAndPush(e.name, null, e.oid);
                    continue;
                }
                try self.setPath(frame.base_len, e.name);
                return .{ .kind = .added, .path = self.path.items, .old_oid = null, .new_oid = e.oid };
            }
            if (self.new_entry == null) {
                const e = self.old_entry.?;
                self.old_entry = null;
                if (e.mode == .directory) {
                    try self.appendDirAndPush(e.name, e.oid, null);
                    continue;
                }
                try self.setPath(frame.base_len, e.name);
                return .{ .kind = .deleted, .path = self.path.items, .old_oid = e.oid, .new_oid = null };
            }

            const oe = self.old_entry.?;
            const ne = self.new_entry.?;
            const cmp = std.mem.order(u8, oe.name, ne.name);
            if (cmp == .lt) {
                self.old_entry = null;
                if (oe.mode == .directory) {
                    try self.appendDirAndPush(oe.name, oe.oid, null);
                    continue;
                }
                try self.setPath(frame.base_len, oe.name);
                return .{ .kind = .deleted, .path = self.path.items, .old_oid = oe.oid, .new_oid = null };
            } else if (cmp == .gt) {
                self.new_entry = null;
                if (ne.mode == .directory) {
                    try self.appendDirAndPush(ne.name, null, ne.oid);
                    continue;
                }
                try self.setPath(frame.base_len, ne.name);
                return .{ .kind = .added, .path = self.path.items, .old_oid = null, .new_oid = ne.oid };
            } else {
                if (oe.mode != ne.mode) {
                    self.old_entry = null;
                    if (oe.mode == .directory) {
                        try self.appendDirAndPush(oe.name, oe.oid, null);
                        continue;
                    }
                    try self.setPath(frame.base_len, oe.name);
                    return .{ .kind = .deleted, .path = self.path.items, .old_oid = oe.oid, .new_oid = null };
                }
                self.old_entry = null;
                self.new_entry = null;
                if (std.mem.eql(u8, &oe.oid.bytes, &ne.oid.bytes)) continue;

                if (oe.mode == .directory) {
                    try self.appendDirAndPush(oe.name, oe.oid, ne.oid);
                    continue;
                }
                try self.setPath(frame.base_len, oe.name);
                return .{ .kind = .modified, .path = self.path.items, .old_oid = oe.oid, .new_oid = ne.oid };
            }
        }
        return null;
    }

    fn setPath(self: *TreeDiff, base_len: usize, name: []const u8) ZightError!void {
        self.path.shrinkRetainingCapacity(base_len);
        self.path.appendSlice(self.allocator, name) catch return error.OutOfMemory;
    }

    fn appendDirAndPush(self: *TreeDiff, name: []const u8, old_oid: ?Oid, new_oid: ?Oid) ZightError!void {
        const frame = &self.stack.items[self.stack.items.len - 1];
        const saved = frame.base_len;
        self.path.shrinkRetainingCapacity(saved);
        self.path.appendSlice(self.allocator, name) catch return error.OutOfMemory;
        errdefer self.path.shrinkRetainingCapacity(saved);
        self.path.append(self.allocator, '/') catch return error.OutOfMemory;
        try self.pushFrame(old_oid, new_oid, self.path.items.len);
    }
};

/// 读取两个 blob 并计算行级 diff。调用方拥有返回切片。
pub fn diffBlobLines(allocator: Allocator, reader: *Reader, old_oid: Oid, new_oid: Oid) ZightError![]DiffOp {
    var old_obj = try reader.readObject(allocator, old_oid);
    defer old_obj.deinit(allocator);
    if (old_obj.type != .blob) return error.MalformedObject;

    var new_obj = try reader.readObject(allocator, new_oid);
    defer new_obj.deinit(allocator);
    if (new_obj.type != .blob) return error.MalformedObject;

    const old_lines = try line_diff.splitLines(allocator, old_obj.content);
    defer allocator.free(old_lines);
    const new_lines = try line_diff.splitLines(allocator, new_obj.content);
    defer allocator.free(new_lines);

    return line_diff.diff(allocator, old_lines, new_lines) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

const testing = std.testing;
const Repo = @import("repo.zig").Repo;
const ref = @import("ref.zig");

fn openFixture(name: []const u8) !Repo {
    const path = try std.fmt.allocPrint(testing.allocator, "test/fixtures/{s}", .{name});
    defer testing.allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    return Repo.open(io, testing.allocator, path);
}

test "TreeDiff: added file (initial → add nested)" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    const parent = (try rdr.firstParent(testing.allocator, tip)).?;
    const old_tree = try rdr.commitTree(testing.allocator, parent);
    const new_tree = try rdr.commitTree(testing.allocator, tip);

    var d = try TreeDiff.open(&rdr, testing.allocator, old_tree, new_tree, null);
    defer d.close();

    var added_nested = false;
    var change_count: usize = 0;
    while (try d.next()) |change| {
        change_count += 1;
        if (std.mem.eql(u8, change.path, "src/nested.txt")) {
            try testing.expectEqual(ChangeKind.added, change.kind);
            try testing.expect(change.old_oid == null);
            try testing.expect(change.new_oid != null);
            added_nested = true;
        }
    }
    try testing.expect(added_nested);
    try testing.expectEqual(@as(usize, 1), change_count);
}

test "TreeDiff: deleted file (reverse)" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    const parent = (try rdr.firstParent(testing.allocator, tip)).?;
    const old_tree = try rdr.commitTree(testing.allocator, tip);
    const new_tree = try rdr.commitTree(testing.allocator, parent);

    var d = try TreeDiff.open(&rdr, testing.allocator, old_tree, new_tree, null);
    defer d.close();

    var deleted_nested = false;
    while (try d.next()) |change| {
        if (std.mem.eql(u8, change.path, "src/nested.txt")) {
            try testing.expectEqual(ChangeKind.deleted, change.kind);
            try testing.expect(change.old_oid != null);
            try testing.expect(change.new_oid == null);
            deleted_nested = true;
        }
    }
    try testing.expect(deleted_nested);
}

test "TreeDiff: identical trees yield no changes" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    const tree = try rdr.commitTree(testing.allocator, tip);

    var d = try TreeDiff.open(&rdr, testing.allocator, tree, tree, null);
    defer d.close();

    while (try d.next()) |_| {
        try testing.expect(false); // should not yield any changes
    }
}

test "TreeDiff: null old tree (all added)" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    const tree = try rdr.commitTree(testing.allocator, tip);

    var d = try TreeDiff.open(&rdr, testing.allocator, null, tree, null);
    defer d.close();

    var count: usize = 0;
    while (try d.next()) |change| {
        try testing.expectEqual(ChangeKind.added, change.kind);
        count += 1;
    }
    try testing.expect(count > 0);
}

test "TreeDiff: null new tree (all deleted)" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    const tree = try rdr.commitTree(testing.allocator, tip);

    var d = try TreeDiff.open(&rdr, testing.allocator, tree, null, null);
    defer d.close();

    var count: usize = 0;
    while (try d.next()) |change| {
        try testing.expectEqual(ChangeKind.deleted, change.kind);
        count += 1;
    }
    try testing.expect(count > 0);
}

test "TreeDiff: modified file" {
    var repo = try openFixture("edge");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    // Walk back to find rewrite.txt changes: "rewrite all" vs "add rewrite"
    var commit = try ref.resolveHead(&repo);
    var prev_blob: ?Oid = null;
    var cur_blob: ?Oid = null;
    while (true) {
        const tree = try rdr.commitTree(testing.allocator, commit);
        const blob = try tree_browse.findFile(testing.allocator, &rdr, tree, "rewrite.txt");
        if (blob != null) {
            if (cur_blob != null) prev_blob = cur_blob;
            cur_blob = blob;
            if (prev_blob != null and !std.mem.eql(u8, &prev_blob.?.bytes, &cur_blob.?.bytes)) break;
        }
        commit = (try rdr.firstParent(testing.allocator, commit)) orelse break;
    }
    try testing.expect(prev_blob != null);

    const ops = try diffBlobLines(testing.allocator, &rdr, prev_blob.?, cur_blob.?);
    defer testing.allocator.free(ops);

    var has_delete = false;
    var has_insert = false;
    for (ops) |op| {
        if (op.op == .delete) has_delete = true;
        if (op.op == .insert) has_insert = true;
    }
    try testing.expect(has_delete);
    try testing.expect(has_insert);
}

test "TreeDiff: both null trees" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    var d = try TreeDiff.open(&rdr, testing.allocator, null, null, null);
    defer d.close();

    const result = try d.next();
    try testing.expect(result == null);
}

test "diffBlobLines: identical blob" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    const tree = try rdr.commitTree(testing.allocator, tip);
    const blob = (try tree_browse.findFile(testing.allocator, &rdr, tree, "README.md")).?;

    const ops = try diffBlobLines(testing.allocator, &rdr, blob, blob);
    defer testing.allocator.free(ops);

    for (ops) |op| {
        try testing.expectEqual(line_diff.Op.equal, op.op);
    }
}

test "diffBlobLines: non-blob returns MalformedObject" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    try testing.expectError(error.MalformedObject, diffBlobLines(testing.allocator, &rdr, tip, tip));
}

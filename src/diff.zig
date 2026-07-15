//! 文件级 tree diff + 行级 diff 便捷函数。
//!
//! 职责（§2.4）：给定两个 tree oid，深度优先并行遍历，按路径归并比较，
//! 产出文件级变更（added/deleted/modified）。git tree 条目按名排序，
//! DFS 产出的全路径满足字典序，可直接归并连接。

const std = @import("std");
const Allocator = std.mem.Allocator;

const Oid = @import("hash.zig").Oid;
const Reader = @import("reader.zig").Reader;
const tree_browse = @import("tree_browse.zig");
const TreeWalker = tree_browse.TreeWalker;
const WalkEntry = tree_browse.WalkEntry;
const TreeMode = tree_browse.TreeMode;
const line_diff = @import("line_diff.zig");
const DiffOp = line_diff.DiffOp;
const ZightError = @import("error.zig").ZightError;

pub const ChangeKind = enum { added, deleted, modified };

/// 单条文件变更。`path` 指向 TreeDiff 内部 walker 缓冲，在下一次 `next` 前有效。
pub const FileChange = struct {
    kind: ChangeKind,
    path: []const u8,
    old_oid: ?Oid, // null for added
    new_oid: ?Oid, // null for deleted
};

/// 两个 tree 的文件级 diff 迭代器。调用方须 `close` 释放。
pub const TreeDiff = struct {
    old_walker: ?TreeWalker,
    new_walker: ?TreeWalker,
    old_entry: ?WalkEntry,
    new_entry: ?WalkEntry,

    /// `old_tree` 为 null 表示全部新增；`new_tree` 为 null 表示全部删除。
    pub fn open(reader: *Reader, allocator: Allocator, old_tree: ?Oid, new_tree: ?Oid) ZightError!TreeDiff {
        var d: TreeDiff = .{
            .old_walker = null,
            .new_walker = null,
            .old_entry = null,
            .new_entry = null,
        };
        errdefer d.close();
        if (old_tree) |oid| d.old_walker = try TreeWalker.open(reader, allocator, oid);
        if (new_tree) |oid| d.new_walker = try TreeWalker.open(reader, allocator, oid);
        return d;
    }

    pub fn close(self: *TreeDiff) void {
        if (self.old_walker) |*w| w.close();
        if (self.new_walker) |*w| w.close();
    }

    /// 拉取下一条变更；无更多变更返回 `null`。
    pub fn next(self: *TreeDiff) ZightError!?FileChange {
        while (true) {
            if (self.old_entry == null) self.old_entry = try self.advanceOld();
            if (self.new_entry == null) self.new_entry = try self.advanceNew();

            if (self.old_entry == null and self.new_entry == null) return null;

            if (self.old_entry == null) {
                const e = self.new_entry.?;
                self.new_entry = null;
                return .{ .kind = .added, .path = e.path, .old_oid = null, .new_oid = e.oid };
            }
            if (self.new_entry == null) {
                const e = self.old_entry.?;
                self.old_entry = null;
                return .{ .kind = .deleted, .path = e.path, .old_oid = e.oid, .new_oid = null };
            }

            const oe = self.old_entry.?;
            const ne = self.new_entry.?;
            const cmp = std.mem.order(u8, oe.path, ne.path);
            if (cmp == .lt) {
                self.old_entry = null;
                return .{ .kind = .deleted, .path = oe.path, .old_oid = oe.oid, .new_oid = null };
            } else if (cmp == .gt) {
                self.new_entry = null;
                return .{ .kind = .added, .path = ne.path, .old_oid = null, .new_oid = ne.oid };
            } else {
                self.old_entry = null;
                self.new_entry = null;
                if (!std.mem.eql(u8, &oe.oid.bytes, &ne.oid.bytes)) {
                    return .{ .kind = .modified, .path = oe.path, .old_oid = oe.oid, .new_oid = ne.oid };
                }
            }
        }
    }

    fn advanceOld(self: *TreeDiff) ZightError!?WalkEntry {
        const w = &(self.old_walker orelse return null);
        while (try w.next()) |entry| {
            if (entry.mode == .directory) continue;
            return entry;
        }
        return null;
    }

    fn advanceNew(self: *TreeDiff) ZightError!?WalkEntry {
        const w = &(self.new_walker orelse return null);
        while (try w.next()) |entry| {
            if (entry.mode == .directory) continue;
            return entry;
        }
        return null;
    }
};

/// 读取两个 blob 并计算行级 diff。调用方拥有返回切片。
pub fn diffBlobLines(allocator: Allocator, reader: *Reader, old_oid: Oid, new_oid: Oid) ZightError![]DiffOp {
    var old_obj = try reader.readObject(old_oid);
    defer old_obj.deinit(allocator);
    if (old_obj.type != .blob) return error.MalformedObject;

    var new_obj = try reader.readObject(new_oid);
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

    var d = try TreeDiff.open(&rdr, testing.allocator, old_tree, new_tree);
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

    var d = try TreeDiff.open(&rdr, testing.allocator, old_tree, new_tree);
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

    var d = try TreeDiff.open(&rdr, testing.allocator, tree, tree);
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

    var d = try TreeDiff.open(&rdr, testing.allocator, null, tree);
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

    var d = try TreeDiff.open(&rdr, testing.allocator, tree, null);
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

    var d = try TreeDiff.open(&rdr, testing.allocator, null, null);
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

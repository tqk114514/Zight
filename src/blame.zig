//! blame：按行追溯到对应 commit。
//!
//! 职责（§2.4）：给定 commit 与文件路径，逐行返回该行最后修改所在的 commit。
//! 算法：沿 first-parent 反向遍历，对相邻 blob 版本做 Myers diff；
//! "insert" 行归当前 commit，"equal" 行通过 line_map 推迟到 parent 继续追溯。
//! first-parent 策略对 merge commit 只追溯主线，侧分支引入的行归 merge 本身。

const std = @import("std");
const Allocator = std.mem.Allocator;

const Oid = @import("hash.zig").Oid;
const Reader = @import("reader.zig").Reader;
const Repo = @import("repo.zig").Repo;
const ZightError = @import("error.zig").ZightError;
const tree_browse = @import("tree_browse.zig");
const line_diff = @import("line_diff.zig");
const ref = @import("ref.zig");

/// blame 结果。调用方须 `deinit` 释放。
/// `lines[i]` 与 `commits[i]` 一一对应：第 i 行（0-based）由 `commits[i]` 最后修改。
/// `lines[i]` 指向 `blob_content` 内部，随 `blob_content` 一并释放。
pub const Blame = struct {
    lines: [][]const u8,
    commits: []Oid,
    blob_content: []u8,

    pub fn deinit(self: *Blame, gpa: Allocator) void {
        gpa.free(self.blob_content);
        gpa.free(self.lines);
        gpa.free(self.commits);
    }
};

/// 对 HEAD 中的 `path` 文件做 blame。
pub fn blame(allocator: Allocator, reader: *Reader, path: []const u8) ZightError!Blame {
    const head = try ref.resolveHead(reader.repo);
    return blameAt(allocator, reader, head, path);
}

/// 对 `commit_oid` 中的 `path` 文件做 blame。
/// 文件不存在返回 `NotFound`；对象类型非 blob 返回 `MalformedObject`。
pub fn blameAt(allocator: Allocator, reader: *Reader, commit_oid: Oid, path: []const u8) ZightError!Blame {
    const tree = try reader.commitTree(allocator, commit_oid);
    const blob_oid = (try tree_browse.findFile(allocator, reader, tree, path)) orelse return error.NotFound;

    var blob_obj = try reader.readObject(blob_oid);
    defer blob_obj.deinit(allocator);
    if (blob_obj.type != .blob) return error.MalformedObject;

    const blob_content = try allocator.dupe(u8, blob_obj.content);
    errdefer allocator.free(blob_content);
    const lines = try line_diff.splitLines(allocator, blob_content);
    errdefer allocator.free(lines);

    var commits = try allocator.alloc(Oid, lines.len);
    errdefer allocator.free(commits);

    // line_map[i] = 当前 cur_blob 中对应 HEAD 第 i 行的行号；null 表示已归责。
    const line_map = try allocator.alloc(?usize, lines.len);
    defer allocator.free(line_map);
    for (line_map, 0..) |*m, i| m.* = i;

    var cur_commit = commit_oid;
    var cur_blob_oid = blob_oid;

    while (true) {
        const parent = (try reader.firstParent(allocator, cur_commit)) orelse break;
        const parent_tree = try reader.commitTree(allocator, parent);
        const parent_blob_oid_opt = try tree_browse.findFile(allocator, reader, parent_tree, path);

        if (parent_blob_oid_opt == null) {
            for (line_map, 0..) |m, i| {
                if (m != null) commits[i] = cur_commit;
            }
            break;
        }
        const parent_blob_oid = parent_blob_oid_opt.?;

        if (std.mem.eql(u8, &parent_blob_oid.bytes, &cur_blob_oid.bytes)) {
            cur_commit = parent;
            continue;
        }

        var cur_obj = try reader.readObject(cur_blob_oid);
        defer cur_obj.deinit(allocator);
        var parent_obj = try reader.readObject(parent_blob_oid);
        defer parent_obj.deinit(allocator);

        const cur_lines = try line_diff.splitLines(allocator, cur_obj.content);
        defer allocator.free(cur_lines);
        const parent_lines = try line_diff.splitLines(allocator, parent_obj.content);
        defer allocator.free(parent_lines);

        const ops = try line_diff.diff(allocator, parent_lines, cur_lines);
        defer allocator.free(ops);

        // trans[j]：cur_blob 第 j 行对应的 parent_blob 行号；null 表示 insert（新行）。
        var trans = try allocator.alloc(?usize, cur_lines.len);
        defer allocator.free(trans);
        for (trans) |*t| t.* = null;
        for (ops) |op| {
            switch (op.op) {
                .equal => trans[op.b_idx.?] = op.a_idx.?,
                else => {},
            }
        }

        for (line_map, 0..) |*m, i| {
            if (m.*) |cur_idx| {
                const new_idx = trans[cur_idx];
                if (new_idx == null) {
                    commits[i] = cur_commit;
                    m.* = null;
                } else {
                    m.* = new_idx;
                }
            }
        }

        cur_commit = parent;
        cur_blob_oid = parent_blob_oid;
    }

    for (line_map, 0..) |m, i| {
        if (m != null) commits[i] = cur_commit;
    }

    return Blame{
        .lines = lines,
        .commits = commits,
        .blob_content = blob_content,
    };
}

const testing = std.testing;

fn openFixture(name: []const u8) !Repo {
    const path = try std.fmt.allocPrint(testing.allocator, "test/fixtures/{s}", .{name});
    defer testing.allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    return Repo.open(io, testing.allocator, path);
}

fn rootCommit(rdr: *Reader, head: Oid) !Oid {
    var cur = head;
    while (try rdr.firstParent(testing.allocator, cur)) |p| cur = p;
    return cur;
}

test "blame: tiny README.md from initial commit" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const head = try ref.resolveHead(&repo);
    const root = try rootCommit(&rdr, head);

    var b = try blame(testing.allocator, &rdr, "README.md");
    defer b.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), b.lines.len);
    try testing.expectEqualStrings("hello zight", b.lines[0]);
    try testing.expect(!std.mem.eql(u8, &b.commits[0].bytes, &head.bytes));
    try testing.expect(std.mem.eql(u8, &b.commits[0].bytes, &root.bytes));
}

test "blame: tiny src/nested.txt from HEAD" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const head = try ref.resolveHead(&repo);

    var b = try blame(testing.allocator, &rdr, "src/nested.txt");
    defer b.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), b.lines.len);
    try testing.expectEqualStrings("nested file", b.lines[0]);
    try testing.expect(std.mem.eql(u8, &b.commits[0].bytes, &head.bytes));
}

test "blame: edge rewrite.txt all from rewrite-all commit" {
    var repo = try openFixture("edge");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const head = try ref.resolveHead(&repo);

    // Walk back to find the commit where rewrite.txt blob last changed.
    // rewrite_all_commit = the commit BEFORE the change (where "x,y,z" was introduced).
    var commit = head;
    var rewrite_all_commit: ?Oid = null;
    var prev_commit: ?Oid = null;
    var prev_blob: ?Oid = null;
    while (true) {
        const tree = try rdr.commitTree(testing.allocator, commit);
        const blob = try tree_browse.findFile(testing.allocator, &rdr, tree, "rewrite.txt");
        if (blob != null) {
            if (prev_blob != null and !std.mem.eql(u8, &prev_blob.?.bytes, &blob.?.bytes)) {
                rewrite_all_commit = prev_commit;
                break;
            }
            prev_blob = blob;
            prev_commit = commit;
        }
        commit = (try rdr.firstParent(testing.allocator, commit)) orelse break;
    }
    try testing.expect(rewrite_all_commit != null);

    var b = try blame(testing.allocator, &rdr, "rewrite.txt");
    defer b.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), b.lines.len);
    try testing.expectEqualStrings("x", b.lines[0]);
    try testing.expectEqualStrings("y", b.lines[1]);
    try testing.expectEqualStrings("z", b.lines[2]);
    for (b.commits) |c| {
        try testing.expect(std.mem.eql(u8, &c.bytes, &rewrite_all_commit.?.bytes));
    }
}

test "blame: edge empty file has zero lines" {
    var repo = try openFixture("edge");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    var b = try blame(testing.allocator, &rdr, "empty.txt");
    defer b.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), b.lines.len);
    try testing.expectEqual(@as(usize, 0), b.commits.len);
}

test "blame: edge oneline.txt from root commit" {
    var repo = try openFixture("edge");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const head = try ref.resolveHead(&repo);
    const root = try rootCommit(&rdr, head);

    var b = try blame(testing.allocator, &rdr, "oneline.txt");
    defer b.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), b.lines.len);
    try testing.expectEqualStrings("only line", b.lines[0]);
    try testing.expect(std.mem.eql(u8, &b.commits[0].bytes, &root.bytes));
}

test "blame: missing file returns NotFound" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    try testing.expectError(error.NotFound, blame(testing.allocator, &rdr, "nonexistent.txt"));
}

test "blame: packed data.txt attributes modified lines correctly" {
    var repo = try openFixture("packed");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    var b = try blame(testing.allocator, &rdr, "data.txt");
    defer b.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 20), b.lines.len);
    try testing.expectEqualStrings("modified line 10", b.lines[9]);
    try testing.expectEqualStrings("modified line 15", b.lines[14]);

    // Line 9 (modified at v2) differs from line 8 (unchanged from v1).
    try testing.expect(!std.mem.eql(u8, &b.commits[9].bytes, &b.commits[8].bytes));
    // Line 14 (modified at v3) differs from line 13 (unchanged from v1).
    try testing.expect(!std.mem.eql(u8, &b.commits[14].bytes, &b.commits[13].bytes));
    // Unmodified lines share the same blame (v1).
    try testing.expect(std.mem.eql(u8, &b.commits[0].bytes, &b.commits[8].bytes));
    try testing.expect(std.mem.eql(u8, &b.commits[0].bytes, &b.commits[13].bytes));
}

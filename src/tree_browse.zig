//! 文件树浏览：基于 tree 对象递归列举。
//!
//! 职责（§2.4）：给定一个 tree oid（通常来自 commit 的 tree 字段），
//! 深度优先递归遍历所有条目，按路径产出 (path, mode, oid)。
//! 返回迭代器，调用方逐条 `next` 拉取（§6.2）。目录条目先于其子条目产出（前序）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("hash.zig");
const Oid = hash.Oid;
const reader_mod = @import("reader.zig");
const Reader = reader_mod.Reader;
const ZightError = @import("error.zig").ZightError;

/// tree 条目类型（git mode）。
pub const TreeMode = enum {
    file,
    executable,
    symlink,
    directory,
    submodule,
};

/// 单条遍历结果。`path` 指向 walker 内部缓冲，在下一次 `next` 前有效。
pub const WalkEntry = struct {
    path: []const u8,
    mode: TreeMode,
    oid: Oid,
};

const RawEntry = struct {
    mode: TreeMode,
    name: []const u8,
    oid: Oid,
};

const Frame = struct {
    buf: []u8, // owns memory（obj.buf）
    content: []const u8, // tree body（obj.content，buf 的子切片或等同）
    pos: usize,
    base_len: usize, // path 长度在本帧入栈时的值
};

/// 递归 tree 遍历器。调用方须 `close` 释放。
pub const TreeWalker = struct {
    reader: *Reader,
    allocator: Allocator,
    stack: std.ArrayList(Frame),
    path: std.ArrayList(u8),
    pending_dir: ?struct { oid: Oid } = null,

    /// 从 `root_oid` 处的 tree 对象开始遍历。
    pub fn open(reader: *Reader, allocator: Allocator, root_oid: Oid) ZightError!TreeWalker {
        var w: TreeWalker = .{
            .reader = reader,
            .allocator = allocator,
            .stack = .empty,
            .path = .empty,
        };
        errdefer w.close();
        try w.pushTree(root_oid, 0);
        return w;
    }

    pub fn close(self: *TreeWalker) void {
        for (self.stack.items) |*f| self.allocator.free(f.buf);
        self.stack.deinit(self.allocator);
        self.path.deinit(self.allocator);
    }

    fn pushTree(self: *TreeWalker, oid: Oid, base_len: usize) ZightError!void {
        var obj = try self.reader.readObject(oid);
        errdefer obj.deinit(self.allocator);
        if (obj.type != .tree) return error.MalformedObject;
        const buf = obj.buf;
        const content = obj.content;
        obj.buf = &.{};
        obj.content = &.{};
        try self.stack.append(self.allocator, .{
            .buf = buf,
            .content = content,
            .pos = 0,
            .base_len = base_len,
        });
    }

    /// 拉取下一条目；遍历结束返回 `null`。目录先于其子条目产出。
    pub fn next(self: *TreeWalker) ZightError!?WalkEntry {
        if (self.pending_dir) |p| {
            self.pending_dir = null;
            try self.path.append(self.allocator, '/');
            try self.pushTree(p.oid, self.path.items.len);
        }

        while (self.stack.items.len > 0) {
            const fi = self.stack.items.len - 1;
            const frame = &self.stack.items[fi];
            const opt = parseEntry(frame.content, &frame.pos);
            if (opt) |e| {
                self.path.shrinkRetainingCapacity(frame.base_len);
                try self.path.appendSlice(self.allocator, e.name);
                if (e.mode == .directory) {
                    self.pending_dir = .{ .oid = e.oid };
                }
                return WalkEntry{
                    .path = self.path.items,
                    .mode = e.mode,
                    .oid = e.oid,
                };
            } else {
                self.allocator.free(frame.buf);
                self.path.shrinkRetainingCapacity(frame.base_len);
                _ = self.stack.pop();
            }
        }
        return null;
    }
};

/// 解析 tree 内容中 `pos` 处的下一条目；越界返回 `null`。
fn parseEntry(buf: []const u8, pos: *usize) ?RawEntry {
    if (pos.* >= buf.len) return null;

    const space = std.mem.indexOfScalarPos(u8, buf, pos.*, ' ') orelse return null;
    const mode_str = buf[pos.*..space];
    const mode_int = std.fmt.parseInt(u32, mode_str, 8) catch return null;
    const mode = parseMode(mode_int) orelse return null;

    const nul = std.mem.indexOfScalarPos(u8, buf, space + 1, 0) orelse return null;
    const name = buf[space + 1 .. nul];

    const sha_start = nul + 1;
    if (sha_start + 20 > buf.len) return null;
    var oid: Oid = undefined;
    @memcpy(&oid.bytes, buf[sha_start..][0..20]);

    pos.* = sha_start + 20;
    return RawEntry{ .mode = mode, .name = name, .oid = oid };
}

fn parseMode(m: u32) ?TreeMode {
    return switch (m) {
        0o100644 => .file,
        0o100755 => .executable,
        0o120000 => .symlink,
        0o40000 => .directory,
        0o160000 => .submodule,
        else => null,
    };
}

/// 在 `tree_oid` 处的 tree 中查找路径为 `path` 的文件，返回其 oid。
/// `path` 须为相对路径、以 `/` 分隔（如 `src/nested.txt`）。
/// 文件不存在或为目录时返回 `null`。
pub fn findFile(allocator: Allocator, reader: *Reader, tree_oid: Oid, path: []const u8) ZightError!?Oid {
    var w = try TreeWalker.open(reader, allocator, tree_oid);
    defer w.close();
    while (try w.next()) |entry| {
        if (entry.mode == .directory) continue;
        if (std.mem.eql(u8, entry.path, path)) return entry.oid;
    }
    return null;
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

/// 从 HEAD 解析 commit，取其 tree oid。
fn headTree(repo: *Repo, rdr: *Reader) !Oid {
    const tip = try ref.resolveHead(repo);
    var obj = try rdr.readObject(tip);
    defer obj.deinit(testing.allocator);
    const nl = std.mem.indexOfScalar(u8, obj.content, '\n') orelse return error.MalformedObject;
    const line = obj.content[0..nl];
    if (!std.mem.startsWith(u8, line, "tree ")) return error.MalformedObject;
    return Oid.fromHex(line[5..]) catch error.MalformedObject;
}

test "TreeWalker tiny: lists README.md and src/nested.txt" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const root = try headTree(&repo, &rdr);
    var w = try TreeWalker.open(&rdr, testing.allocator, root);
    defer w.close();

    var paths = std.ArrayList([]const u8).empty;
    defer {
        for (paths.items) |p| testing.allocator.free(p);
        paths.deinit(testing.allocator);
    }

    while (try w.next()) |entry| {
        const dup = try testing.allocator.dupe(u8, entry.path);
        try paths.append(testing.allocator, dup);
    }

    var found_readme = false;
    var found_src = false;
    var found_nested = false;
    for (paths.items) |p| {
        if (std.mem.eql(u8, p, "README.md")) found_readme = true;
        if (std.mem.eql(u8, p, "src")) found_src = true;
        if (std.mem.eql(u8, p, "src/nested.txt")) found_nested = true;
    }
    try testing.expect(found_readme);
    try testing.expect(found_src);
    try testing.expect(found_nested);
    try testing.expectEqual(@as(usize, 3), paths.items.len);
}

test "TreeWalker edge: deep nesting (8 levels)" {
    var repo = try openFixture("edge");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const root = try headTree(&repo, &rdr);
    var w = try TreeWalker.open(&rdr, testing.allocator, root);
    defer w.close();

    var found_deep = false;
    while (try w.next()) |entry| {
        if (std.mem.eql(u8, entry.path, "a/b/c/d/e/f/g/h/leaf.txt")) {
            found_deep = true;
            try testing.expectEqual(TreeMode.file, entry.mode);
        }
    }
    try testing.expect(found_deep);
}

test "TreeWalker edge: empty file and oneline file" {
    var repo = try openFixture("edge");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const root = try headTree(&repo, &rdr);
    var w = try TreeWalker.open(&rdr, testing.allocator, root);
    defer w.close();

    var found_empty = false;
    var found_oneline = false;
    while (try w.next()) |entry| {
        if (std.mem.eql(u8, entry.path, "empty.txt")) {
            found_empty = true;
            try testing.expectEqual(TreeMode.file, entry.mode);
        }
        if (std.mem.eql(u8, entry.path, "oneline.txt")) {
            found_oneline = true;
        }
    }
    try testing.expect(found_empty);
    try testing.expect(found_oneline);
}

test "TreeWalker: directories yielded before children" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const root = try headTree(&repo, &rdr);
    var w = try TreeWalker.open(&rdr, testing.allocator, root);
    defer w.close();

    var src_idx: ?usize = null;
    var nested_idx: ?usize = null;
    var i: usize = 0;
    while (try w.next()) |entry| {
        if (std.mem.eql(u8, entry.path, "src")) {
            src_idx = i;
            try testing.expectEqual(TreeMode.directory, entry.mode);
        }
        if (std.mem.eql(u8, entry.path, "src/nested.txt")) nested_idx = i;
        i += 1;
    }
    try testing.expect(src_idx != null);
    try testing.expect(nested_idx != null);
    try testing.expect(src_idx.? < nested_idx.?);
}

test "TreeWalker: missing tree returns error" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const zero = Oid.fromHex("0000000000000000000000000000000000000000") catch unreachable;
    try testing.expectError(error.NotFound, TreeWalker.open(&rdr, testing.allocator, zero));
}

test "findFile locates nested file" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const root = try headTree(&repo, &rdr);
    const oid = (try findFile(testing.allocator, &rdr, root, "src/nested.txt")).?;
    var obj = try rdr.readObject(oid);
    defer obj.deinit(testing.allocator);
    try testing.expectEqualStrings("nested file\n", obj.content);
}

test "findFile missing returns null" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const root = try headTree(&repo, &rdr);
    const oid = try findFile(testing.allocator, &rdr, root, "nonexistent.txt");
    try testing.expect(oid == null);
}

test "findFile skips directory matching name" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const root = try headTree(&repo, &rdr);
    const oid = try findFile(testing.allocator, &rdr, root, "src");
    try testing.expect(oid == null);
}

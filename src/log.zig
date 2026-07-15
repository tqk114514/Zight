//! commit 历史遍历。
//!
//! 职责（§2.4）：从给定 tip（ref 解析后的 oid）出发，按 committer time
//! 降序遍历 commit 历史。使用优先队列（max-heap）+ visited 集合，流式产出，
//! 不先全量 load 再排序（§6.2）。返回迭代器，调用方逐条 `next` 拉取。
//!
//! 资源所有权：`Log` 拥有内部队列与 visited 集合，调用方须 `close` 释放。
//! `next` 返回的 `LogEntry` 拥有 `buf` 与 `parents`，调用方须 `deinit` 释放。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const PriorityQueue = std.PriorityQueue;

const hash = @import("hash.zig");
const Oid = hash.Oid;
const reader_mod = @import("reader.zig");
const Reader = reader_mod.Reader;
const ZightError = @import("error.zig").ZightError;

/// 单条 commit 历史记录。
///
/// `buf` 拥有原始 commit 内容；`parents` 是独立分配的 oid 切片；
/// `message` 指向 `buf` 内部，随 `buf` 一并释放。调用方用 `deinit` 释放。
pub const LogEntry = struct {
    oid: Oid,
    tree: Oid,
    parents: []Oid,
    author_time: i64,
    committer_time: i64,
    message: []const u8,
    buf: []u8,

    pub fn deinit(self: *LogEntry, gpa: Allocator) void {
        gpa.free(self.buf);
        gpa.free(self.parents);
        self.buf = &.{};
        self.parents = &.{};
        self.message = &.{};
    }
};

const QueueEntry = struct {
    oid: Oid,
    committer_time: i64,
    tree: Oid,
    parents: []Oid,
    author_time: i64,
    message: []const u8,
    buf: []u8,
};

fn compare(_: void, a: QueueEntry, b: QueueEntry) Order {
    return std.math.order(b.committer_time, a.committer_time);
}

/// commit 历史迭代器。调用方须 `close` 释放。
pub const Log = struct {
    reader: *Reader,
    allocator: Allocator,
    queue: PriorityQueue(QueueEntry, void, compare),
    visited: std.AutoHashMap([20]u8, void),

    /// 从 `tip` 开始遍历历史。`tip` 必须为 commit oid（由 ref 解析得到）。
    pub fn open(reader: *Reader, allocator: Allocator, tip: Oid) ZightError!Log {
        var log: Log = .{
            .reader = reader,
            .allocator = allocator,
            .queue = PriorityQueue(QueueEntry, void, compare).initContext({}),
            .visited = std.AutoHashMap([20]u8, void).init(allocator),
        };
        errdefer log.close();
        try log.pushIfNew(tip);
        return log;
    }

    pub fn close(self: *Log) void {
        while (self.queue.pop()) |entry| {
            self.allocator.free(entry.buf);
            self.allocator.free(entry.parents);
        }
        self.queue.deinit(self.allocator);
        self.visited.deinit();
    }

    /// 拉取下一条 commit；历史耗尽返回 `null`。
    pub fn next(self: *Log) ZightError!?LogEntry {
        const entry = self.queue.pop() orelse return null;
        errdefer {
            self.allocator.free(entry.buf);
            self.allocator.free(entry.parents);
        }

        for (entry.parents) |parent| {
            try self.pushIfNew(parent);
        }

        return LogEntry{
            .oid = entry.oid,
            .tree = entry.tree,
            .parents = entry.parents,
            .author_time = entry.author_time,
            .committer_time = entry.committer_time,
            .message = entry.message,
            .buf = entry.buf,
        };
    }

    fn pushIfNew(self: *Log, oid: Oid) ZightError!void {
        if (self.visited.contains(oid.bytes)) return;
        try self.visited.put(oid.bytes, {});
        errdefer _ = self.visited.remove(oid.bytes);

        var obj = self.reader.readObject(self.allocator, oid) catch |err| switch (err) {
            error.NotFound => return,
            else => |e| return e,
        };
        errdefer obj.deinit(self.allocator);

        if (obj.type != .commit) return error.MalformedObject;

        var parents: std.ArrayList(Oid) = .empty;
        defer parents.deinit(self.allocator);

        var tree: Oid = undefined;
        var author_time: i64 = 0;
        var committer_time: i64 = 0;
        var message: []const u8 = "";
        try parseCommit(self.allocator, obj.content, &parents, &tree, &author_time, &committer_time, &message);
        const parents_owned = try parents.toOwnedSlice(self.allocator);

        const buf = obj.buf;
        obj.buf = &.{};
        obj.content = &.{};
        errdefer self.allocator.free(buf);
        errdefer self.allocator.free(parents_owned);

        try self.queue.push(self.allocator, .{
            .oid = oid,
            .committer_time = committer_time,
            .tree = tree,
            .parents = parents_owned,
            .author_time = author_time,
            .message = message,
            .buf = buf,
        });
    }
};

/// 解析 commit 内容头部。
///
/// `content` 格式：`tree <40hex>\n[parent <40hex>\n]*author ...\ncommitter ...\n\n<message>`。
/// `parents` 由调用方传入的 ArrayList 累积；`message` 指向 `content` 内部（随 buf 释放）。
fn parseCommit(
    allocator: Allocator,
    content: []const u8,
    parents: *std.ArrayList(Oid),
    tree: *Oid,
    author_time: *i64,
    committer_time: *i64,
    message: *[]const u8,
) ZightError!void {
    const boundary = std.mem.indexOf(u8, content, "\n\n") orelse return error.MalformedObject;
    const header = content[0..boundary];
    message.* = content[boundary + 2 ..];

    var found_tree = false;
    var found_committer = false;
    var it = std.mem.splitScalar(u8, header, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "tree ")) {
            tree.* = Oid.fromHex(line[5..]) catch return error.MalformedObject;
            found_tree = true;
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            const p = Oid.fromHex(line[7..]) catch return error.MalformedObject;
            parents.append(allocator, p) catch return error.OutOfMemory;
        } else if (std.mem.startsWith(u8, line, "author ")) {
            author_time.* = parseTime(line) catch return error.MalformedObject;
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            committer_time.* = parseTime(line) catch return error.MalformedObject;
            found_committer = true;
        }
    }

    if (!found_tree or !found_committer) return error.MalformedObject;
}

/// 从 `author`/`committer` 行提取 unix 时间戳（倒数第二个 token）。
fn parseTime(line: []const u8) ZightError!i64 {
    var it = std.mem.splitBackwardsScalar(u8, line, ' ');
    _ = it.first();
    const ts_str = it.next() orelse return error.MalformedObject;
    return std.fmt.parseInt(i64, ts_str, 10) catch return error.MalformedObject;
}

const testing = std.testing;

fn openFixture(name: []const u8) !Repo {
    const path = try std.fmt.allocPrint(testing.allocator, "test/fixtures/{s}", .{name});
    defer testing.allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    return Repo.open(io, testing.allocator, path);
}

const Repo = @import("repo.zig").Repo;
const ref = @import("ref.zig");

test "Log tiny: 2 commits descending" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    var log = try Log.open(&rdr, testing.allocator, tip);
    defer log.close();

    var count: usize = 0;
    var times: [4]i64 = undefined;
    while (try log.next()) |entry| {
        var e = entry;
        defer e.deinit(testing.allocator);
        if (count == 0) try testing.expectEqualStrings("add nested\n", e.message);
        times[count] = e.committer_time;
        count += 1;
        try testing.expect(count <= 2);
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(times[0] >= times[1]);
}

test "Log merge: visits all commits, merge has 2 parents" {
    var repo = try openFixture("merge");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    var log = try Log.open(&rdr, testing.allocator, tip);
    defer log.close();

    var count: usize = 0;
    var seen_merge = false;
    var seen_octopus = false;
    while (try log.next()) |entry| {
        var e = entry;
        defer e.deinit(testing.allocator);
        count += 1;
        if (std.mem.eql(u8, e.message, "merge feature\n")) {
            seen_merge = true;
            try testing.expectEqual(@as(usize, 2), e.parents.len);
        }
        if (std.mem.startsWith(u8, e.message, "octopus merge")) {
            seen_octopus = true;
            try testing.expectEqual(@as(usize, 3), e.parents.len);
        }
    }
    try testing.expect(count > 0);
    try testing.expect(seen_merge);
    try testing.expect(seen_octopus);
}

test "Log empty: no commits" {
    var repo = try openFixture("empty");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const zero = Oid.fromHex("0000000000000000000000000000000000000000") catch unreachable;
    var log = try Log.open(&rdr, testing.allocator, zero);
    defer log.close();

    const entry = try log.next();
    try testing.expect(entry == null);
}

test "Log times are non-increasing" {
    var repo = try openFixture("merge");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    var log = try Log.open(&rdr, testing.allocator, tip);
    defer log.close();

    var prev: ?i64 = null;
    while (try log.next()) |entry| {
        var e = entry;
        defer e.deinit(testing.allocator);
        if (prev) |p| try testing.expect(e.committer_time <= p);
        prev = e.committer_time;
    }
}

test "Log no duplicates (visited set)" {
    var repo = try openFixture("merge");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    var log = try Log.open(&rdr, testing.allocator, tip);
    defer log.close();

    var seen = std.AutoHashMap([20]u8, void).init(testing.allocator);
    defer seen.deinit();

    while (try log.next()) |entry| {
        var e = entry;
        defer e.deinit(testing.allocator);
        try testing.expect(!seen.contains(e.oid.bytes));
        try seen.put(e.oid.bytes, {});
    }
}

test "Log commit fields: tree oid parsed" {
    var repo = try openFixture("tiny");
    defer repo.close();
    var rdr = try Reader.open(&repo);
    defer rdr.close();

    const tip = try ref.resolveHead(&repo);
    var log = try Log.open(&rdr, testing.allocator, tip);
    defer log.close();

    const entry = try log.next();
    try testing.expect(entry != null);
    var e = entry.?;
    defer e.deinit(testing.allocator);

    var all_zero = true;
    for (e.tree.bytes) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try testing.expect(!all_zero);
}

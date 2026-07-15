//! 基准测试：对 NebulaStudios-Website 实测 §6.1 性能目标。
//!
//! 目标：单个小对象读取 < 1 ms（warm）、log 全量 < 50 ms、
//! 文件树首屏 < 50 ms、blame 单文件 < 100 ms。
//! 不达标时进入 §6.3 索引层流程（rule.md §6.1）。
//!
//! 计时使用 `std.Io.Clock.awake`（单调时钟，Linux 对应 CLOCK_MONOTONIC）。

const std = @import("std");
const zight = @import("zight");
const Io = std.Io;
const Clock = Io.Clock;
const Allocator = std.mem.Allocator;

fn nowTs(io: Io) Io.Timestamp {
    return Clock.awake.now(io);
}

fn elapsedMs(io: Io, start: Io.Timestamp) f64 {
    const ns = start.durationTo(nowTs(io)).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const repo_path = "D:\\Project\\NebulaStudios-Website";

    var repo = zight.Repo.open(io, allocator, repo_path) catch |err| {
        std.debug.print("open failed: {}\n", .{err});
        return;
    };
    defer repo.close();

    var reader = try zight.Reader.open(&repo);
    defer reader.close();

    const head_oid = try zight.ref.resolveHead(&repo);
    var head_hex: [40]u8 = undefined;
    head_oid.toHex(&head_hex);
    std.debug.print("repo: {s}\nHEAD: {s}\n\n", .{ repo_path, head_hex });

    // 1. 单个小对象读取（warm）：读 HEAD commit 两次，计时第二次。
    {
        var o1 = try reader.readObject(head_oid);
        o1.deinit(allocator);
        const start = nowTs(io);
        var o2 = try reader.readObject(head_oid);
        const elapsed = elapsedMs(io, start);
        o2.deinit(allocator);
        std.debug.print("1. object read (warm, HEAD commit): {d:.3} ms  [target <1ms]\n", .{elapsed});
    }

    // 2. log 全量：遍历全部 commit 历史。
    {
        var log = try zight.Log.open(&reader, allocator, head_oid);
        defer log.close();
        const start = nowTs(io);
        var count: usize = 0;
        while (try log.next()) |entry| {
            var e = entry;
            e.deinit(allocator);
            count += 1;
        }
        const elapsed = elapsedMs(io, start);
        std.debug.print("2. log full: {d:.3} ms, {} commits  [target <50ms]\n", .{ elapsed, count });
    }

    // 3. 文件树首屏：读 root tree 对象（首屏主要成本 = 一次 tree 读取）。
    //    另测全量 tree 遍历作为上界参考。
    {
        const root_tree = try reader.commitTree(allocator, head_oid);

        // 首屏：root tree 读取（warm）
        {
            var t1 = try reader.readObject(root_tree);
            t1.deinit(allocator);
            const start = nowTs(io);
            var t2 = try reader.readObject(root_tree);
            const elapsed = elapsedMs(io, start);
            t2.deinit(allocator);
            std.debug.print("3a. tree first-screen (root tree read, warm): {d:.3} ms  [target <50ms]\n", .{elapsed});
        }

        // 全量遍历：所有 tree 对象（上界参考）
        const start = nowTs(io);
        var w = try zight.TreeWalker.open(&reader, allocator, root_tree);
        defer w.close();
        var entries: usize = 0;
        while (try w.next()) |_| entries += 1;
        const elapsed = elapsedMs(io, start);
        std.debug.print("3b. tree full walk: {d:.3} ms, {} entries  [context]\n", .{ elapsed, entries });
    }

    // 4. blame 单文件：自动发现一个根目录文件并 blame。
    {
        const root_tree = try reader.commitTree(allocator, head_oid);
        const target_path = try findShallowFile(allocator, &reader, root_tree);
        defer if (target_path) |p| allocator.free(p);

        if (target_path) |p| {
            const start = nowTs(io);
            var b = try zight.blameAt(allocator, &reader, head_oid, p);
            const elapsed = elapsedMs(io, start);
            const line_count = b.lines.len;
            b.deinit(allocator);
            std.debug.print("4. blame single file ({s}, {} lines): {d:.3} ms  [target <100ms]\n", .{ p, line_count, elapsed });
        } else {
            std.debug.print("4. blame: no suitable file found\n", .{});
        }
    }
}

/// 找一个根目录浅文件（路径无 '/'）。无则回退到任意第一个文件。
fn findShallowFile(allocator: Allocator, reader: *zight.Reader, root_tree: zight.hash.Oid) !?[]u8 {
    var w = try zight.TreeWalker.open(reader, allocator, root_tree);
    defer w.close();
    var fallback: ?[]u8 = null;
    defer if (fallback) |p| allocator.free(p);
    while (try w.next()) |entry| {
        if (entry.mode != .file and entry.mode != .executable) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') == null) {
            return try allocator.dupe(u8, entry.path);
        }
        if (fallback == null) fallback = try allocator.dupe(u8, entry.path);
    }
    if (fallback) |p| {
        const owned = p;
        fallback = null;
        return owned;
    }
    return null;
}

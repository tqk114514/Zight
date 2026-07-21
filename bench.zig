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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip();
    const repo_path = args.next() orelse {
        std.debug.print("usage: bench <repo_path>\n", .{});
        return;
    };

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
        var o1 = try reader.readObject(allocator, head_oid);
        o1.deinit(allocator);
        const start = nowTs(io);
        var o2 = try reader.readObject(allocator, head_oid);
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
            var t1 = try reader.readObject(allocator, root_tree);
            t1.deinit(allocator);
            const start = nowTs(io);
            var t2 = try reader.readObject(allocator, root_tree);
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

    // 4. blame 单文件：自动发现一个根目录文件并 blame（含索引加速）。
    {
        const root_tree = try reader.commitTree(allocator, head_oid);
        const target_path = try findShallowFile(allocator, &reader, root_tree);
        defer if (target_path) |p| allocator.free(p);

        // 构建索引
        {
            const start = nowTs(io);
            zight.index.build(&reader, &repo, allocator) catch |err| {
                std.debug.print("index build failed: {}\n", .{err});
            };
            const elapsed = elapsedMs(io, start);
            std.debug.print("5.  index build: {d:.3} ms  [context]\n", .{elapsed});
        }
        var idx_opt = zight.index.open(&repo, allocator) catch null;
        defer if (idx_opt) |*idx| idx.deinit();

        if (target_path) |p| {
            // 不带索引
            {
                const start = nowTs(io);
                var b = try zight.blameAt(allocator, &reader, null, head_oid, p);
                const elapsed = elapsedMs(io, start);
                const line_count = b.lines.len;
                b.deinit(allocator);
                std.debug.print("4a. blame no index ({s}, {} lines): {d:.3} ms  [target <100ms]\n", .{ p, line_count, elapsed });
            }
            // 带索引
            if (idx_opt) |*idx| {
                const start = nowTs(io);
                var b = try zight.blameAt(allocator, &reader, idx, head_oid, p);
                const elapsed = elapsedMs(io, start);
                const line_count = b.lines.len;
                b.deinit(allocator);
                std.debug.print("4b. blame with index ({s}, {} lines): {d:.3} ms  [target <100ms]\n", .{ p, line_count, elapsed });
            }
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

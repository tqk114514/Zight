//! Zight vs Git 基准测试（rule.md §6.1 性能目标）。
//!
//! 用法:
//!   zig build bench -Doptimize=ReleaseFast -- [repo_path] [iterations] [blame_file]
//!   repo_path    默认 D:\Project\Linux
//!   iterations   默认 3
//!   blame_file   默认 init/main.c
//!
//! 测量:
//!   - setup: 打开 repo + openPacks（1 次，冷启动）
//!   - warm:  repo 常驻，op 重复 N 次取 min/avg（OS 与进程内缓存均已热）
//!   - git:   子进程重复 N 次取 min（OS 缓存热，进程冷）
//!
//! 目标（rule.md §6.1）:
//!   - readObject   < 1 ms (warm)
//!   - logIter 20   < 200 ms
//!   - browseTree   < 500 ms (首屏前 100 条)
//!   - blameFile     < 1 s

const std = @import("std");
const Io = std.Io;
const zight = @import("zight");

const Repo = zight.Repo;
const Pack = zight.Pack;
const Index = zight.Index;

const DEFAULT_REPO = "D:\\Project\\NebulaStudios-Website";
const BLAME_PATH_DEFAULT = "package.json";
const BROWSE_FIRST_N: usize = 100;
const DEFAULT_ITERS: usize = 3;

const Ctx = struct {
    alloc: std.mem.Allocator,
    repo: *Repo,
    packs: []Pack,
    graph: ?Index,
    head_oid: [20]u8,
    tree_oid: [20]u8,
    blame_path: []const u8,
};

fn opReadObject(c: *const Ctx) anyerror!void {
    var obj = try zight.readObject(c.alloc, c.repo, c.packs, c.head_oid);
    defer obj.deinit(c.alloc);
    std.mem.doNotOptimizeAway(obj.data.ptr);
}

fn opLog(c: *const Ctx) anyerror!void {
    const graph_ptr: ?*const Index = if (c.graph) |*g| g else null;
    var it = try zight.logIter(c.repo, c.packs, graph_ptr, &.{c.head_oid}, .{});
    defer it.deinit();
    while (try it.next()) |entry| {
        var e = entry;
        defer e.deinit(c.alloc);
    }
}

fn opBrowseTree(c: *const Ctx) anyerror!void {
    var it = try zight.browseTree(c.repo, c.packs, c.tree_oid, c.alloc);
    defer it.deinit();
    var n: usize = 0;
    while (n < BROWSE_FIRST_N) : (n += 1) {
        var e = (try it.next()) orelse break;
        defer e.deinit(c.alloc);
    }
}

fn opBlame(c: *const Ctx) anyerror!void {
    const graph_ptr: ?*const Index = if (c.graph) |*g| g else null;
    var it = try zight.blameFile(c.repo, c.packs, graph_ptr, c.head_oid, c.blame_path, c.alloc);
    defer it.deinit();
    while (it.next()) |entry| {
        std.mem.doNotOptimizeAway(&entry);
    }
}

const WarmStats = struct {
    min_ms: f64,
    avg_ms: f64,
};

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn msFromNs(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn benchWarm(io: Io, c: *const Ctx, op: *const fn (*const Ctx) anyerror!void, n: usize) !WarmStats {
    var min_ms: f64 = std.math.inf(f64);
    var sum_ms: f64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t = nowNs(io);
        try op(c);
        const ms = msFromNs(nowNs(io) - t);
        if (ms < min_ms) min_ms = ms;
        sum_ms += ms;
    }
    return .{ .min_ms = min_ms, .avg_ms = sum_ms / @as(f64, @floatFromInt(n)) };
}

fn benchGit(io: Io, alloc: std.mem.Allocator, repo_path: []const u8, argv: []const []const u8, n: usize) !f64 {
    var min_ms: f64 = std.math.inf(f64);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t = nowNs(io);
        const result = try std.process.run(alloc, io, .{
            .argv = argv,
            .cwd = .{ .path = repo_path },
        });
        defer {
            alloc.free(result.stdout);
            alloc.free(result.stderr);
        }
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitFailed,
            else => return error.GitFailed,
        }
        const ms = msFromNs(nowNs(io) - t);
        if (ms < min_ms) min_ms = ms;
    }
    return min_ms;
}

fn printLine(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, fmt, args);
    try Io.File.stdout().writeStreamingAll(io, line);
}

fn verdict(warm_min_ms: f64, target_ms: f64) []const u8 {
    return if (warm_min_ms <= target_ms) "PASS" else "FAIL";
}

fn scenario(
    io: Io,
    alloc: std.mem.Allocator,
    c: *const Ctx,
    repo_path: []const u8,
    name: []const u8,
    target_ms: f64,
    op: *const fn (*const Ctx) anyerror!void,
    git_argv: []const []const u8,
    iters: usize,
) !void {
    try printLine(io, "\n[{s}] target <{d}ms\n", .{ name, @as(u64, @intFromFloat(target_ms)) });
    const warm = benchWarm(io, c, op, iters) catch |err| {
        try printLine(io, "  warm: ERROR {s}\n", .{@errorName(err)});
        return;
    };
    try printLine(io, "  warm: min={d:.3} ms  avg={d:.3} ms  {s}\n", .{
        warm.min_ms, warm.avg_ms, verdict(warm.min_ms, target_ms),
    });
    const git_ms = benchGit(io, alloc, repo_path, git_argv, iters) catch |err| {
        try printLine(io, "  git:  ERROR {s}\n", .{@errorName(err)});
        return;
    };
    try printLine(io, "  git:  min={d:.3} ms\n", .{git_ms});
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const repo_path = if (args.len > 1) args[1] else DEFAULT_REPO;
    const iters: usize = if (args.len > 2)
        std.fmt.parseInt(usize, args[2], 10) catch DEFAULT_ITERS
    else
        DEFAULT_ITERS;
    const blame_path = if (args.len > 3) args[3] else BLAME_PATH_DEFAULT;

    try printLine(io, "=== Zight vs Git Benchmark ===\n", .{});
    try printLine(io, "repo: {s}\n", .{repo_path});
    try printLine(io, "iterations: {d}\n", .{iters});
    try printLine(io, "blame file: {s}\n", .{blame_path});

    const t_setup = nowNs(io);
    var warm_repo = try Repo.open(alloc, io, repo_path);
    var warm_packs = try zight.openPacks(&warm_repo, alloc);
    var warm_graph: ?Index = Index.open(&warm_repo, alloc) catch null;
    if (warm_graph == null) {
        const t_build = nowNs(io);
        try Index.build(&warm_repo, warm_packs.items, alloc);
        const build_ms = msFromNs(nowNs(io) - t_build);
        try printLine(io, "index build: {d:.2} ms\n", .{build_ms});
        warm_graph = Index.open(&warm_repo, alloc) catch null;
    }
    defer if (warm_graph) |*g| g.deinit();
    const setup_ms = msFromNs(nowNs(io) - t_setup);
    try printLine(io, "setup (open repo + openPacks + index): {d:.2} ms\n", .{setup_ms});

    const head_oid = try zight.resolveSymrefChain(&warm_repo, "HEAD");
    if (warm_graph) |g| {
        try printLine(io, "index count: {d}\n", .{g.count});
        const head_meta = g.getMeta(head_oid, alloc) catch null;
        if (head_meta) |m| {
            try printLine(io, "HEAD found in index: yes\n", .{});
            var mm = m;
            mm.deinit(alloc);
        } else {
            try printLine(io, "HEAD found in index: NO\n", .{});
        }
    } else {
        try printLine(io, "index: not found\n", .{});
    }

    var commit_obj = try zight.readObject(alloc, &warm_repo, warm_packs.items, head_oid);
    var commit_info = try zight.parseCommit(alloc, commit_obj);
    const tree_oid = commit_info.tree;
    commit_info.deinit(alloc);
    commit_obj.deinit(alloc);

    const ctx = Ctx{
        .alloc = alloc,
        .repo = &warm_repo,
        .packs = warm_packs.items,
        .graph = warm_graph,
        .head_oid = head_oid,
        .tree_oid = tree_oid,
        .blame_path = blame_path,
    };

    try scenario(io, alloc, &ctx, repo_path, "readObject", 1.0, opReadObject, &.{ "git", "cat-file", "-p", "HEAD" }, iters);
    try scenario(io, alloc, &ctx, repo_path, "log all commits", 5000.0, opLog, &.{ "git", "log", "--oneline" }, iters);
    try scenario(io, alloc, &ctx, repo_path, "browseTree first 100", 500.0, opBrowseTree, &.{ "git", "ls-tree", "HEAD" }, iters);
    try scenario(io, alloc, &ctx, repo_path, "blame", 1000.0, opBlame, &.{ "git", "blame", blame_path }, iters);

    for (warm_packs.items) |*p| p.close();
    warm_packs.deinit(alloc);
    warm_repo.close();

    try printLine(io, "\n(done)\n", .{});
}

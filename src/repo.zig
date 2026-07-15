//! 仓库句柄：打开 `.git` 目录、持有 allocator 与 io、提供只读文件访问。
//!
//! 资源所有权：`Repo` 拥有 `git_dir` 与可选的 `worktree_dir` 句柄；
//! 调用方必须 `close` 释放。`io` 与 `allocator` 由调用方拥有，`Repo` 仅持有引用（§3.4）。

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Allocator = std.mem.Allocator;

const ZightError = @import("error.zig").ZightError;

/// 资源上限（§5.2）。可在 `Repo.open` 后修改字段。
pub const Limits = struct {
    loose_object_max: usize = 64 * 1024 * 1024,
    packfile_max: usize = 512 * 1024 * 1024,
    packfile_object_max: usize = 64 * 1024 * 1024,
    index_file_max: usize = 256 * 1024 * 1024,
    delta_depth_max: u32 = 50,
    symref_depth_max: u32 = 5,
    tree_depth_max: u32 = 1024,
};

/// 仓库句柄。
pub const Repo = struct {
    io: Io,
    allocator: Allocator,
    git_dir: Dir,
    /// 非 bare 仓库为 worktree 根；bare 仓库为 null。
    worktree_dir: ?Dir,
    limits: Limits,

    /// 打开 `path` 处的 git 仓库。
    ///
    /// 支持两种形态：
    /// - `path/.git` 为目录：非 bare 仓库，worktree = `path`。
    /// - `path` 自身含 `HEAD` 与 `objects`：bare 仓库，worktree = null。
    ///
    /// `path` 路径长度受 §5.1 约束（此处不做穿越检查，因为是调用方提供的
    /// 仓库根，非不可信数据）。`.git` 内文件访问经 `readGitFile` 走只读模式（§4.4）。
    pub fn open(io: Io, allocator: Allocator, path: []const u8) ZightError!Repo {
        if (path.len == 0 or path.len > @import("path.zig").MAX_PATH_LEN) {
            return error.InvalidPath;
        }

        const dot_git = try joinPath(allocator, path, ".git");
        defer allocator.free(dot_git);

        if (Dir.openDir(.cwd(), io, dot_git, .{ .access_sub_paths = true, .iterate = true })) |git_dir| {
            const worktree = Dir.openDir(.cwd(), io, path, .{ .access_sub_paths = true, .iterate = true }) catch |err| {
                Dir.close(git_dir, io);
                return mapOpenErr(err);
            };
            return .{
                .io = io,
                .allocator = allocator,
                .git_dir = git_dir,
                .worktree_dir = worktree,
                .limits = .{},
            };
        } else |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                const git_dir = Dir.openDir(.cwd(), io, path, .{ .access_sub_paths = true, .iterate = true }) catch |e| {
                    return mapOpenErr(e);
                };
                if (!try isGitDir(io, git_dir)) {
                    Dir.close(git_dir, io);
                    return error.NotAGitRepo;
                }
                return .{
                    .io = io,
                    .allocator = allocator,
                    .git_dir = git_dir,
                    .worktree_dir = null,
                    .limits = .{},
                };
            },
            else => return mapOpenErr(err),
        }
    }

    pub fn close(self: *Repo) void {
        Dir.close(self.git_dir, self.io);
        if (self.worktree_dir) |*wt| Dir.close(wt.*, self.io);
    }

    /// 读取 `.git` 下 `rel_path` 的全部内容。调用方拥有返回内存。
    /// 只读打开（§4.4）。`rel_path` 必须为相对路径（如 `HEAD`、`refs/heads/main`）。
    pub fn readGitFile(self: *Repo, rel_path: []const u8, limit: Io.Limit) ZightError![]u8 {
        return self.git_dir.readFileAlloc(self.io, rel_path, self.allocator, limit) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => mapReadErr(err),
        };
    }

    /// 读取 `.git` 下 `rel_path` 的全部内容（无大小上限，用于已知小文件如 HEAD）。
    pub fn readGitFileUnlimited(self: *Repo, rel_path: []const u8) ZightError![]u8 {
        return self.readGitFile(rel_path, .unlimited);
    }

    /// 是否为 bare 仓库。
    pub fn isBare(self: Repo) bool {
        return self.worktree_dir == null;
    }
};

fn joinPath(allocator: Allocator, base: []const u8, name: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name }) catch return error.OutOfMemory;
}

fn isGitDir(io: Io, dir: Dir) ZightError!bool {
    _ = dir.statFile(io, "HEAD", .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return mapReadErr(err),
    };
    _ = dir.statFile(io, "objects", .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return mapReadErr(err),
    };
    return true;
}

fn mapOpenErr(err: anyerror) ZightError {
    return switch (err) {
        error.FileNotFound, error.NotDir => error.NotAGitRepo,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        else => error.IoFailed,
    };
}

fn mapReadErr(err: anyerror) ZightError {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.StreamTooLong => error.StreamTooLong,
        else => error.IoFailed,
    };
}

const testing = std.testing;

fn openFixture(name: []const u8) !Repo {
    const path = try std.fmt.allocPrint(testing.allocator, "test/fixtures/{s}", .{name});
    defer testing.allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    return Repo.open(io, testing.allocator, path);
}

test "Repo.open tiny fixture" {
    var repo = try openFixture("tiny");
    defer repo.close();
    try std.testing.expect(!repo.isBare());
}

test "Repo.open empty fixture" {
    var repo = try openFixture("empty");
    defer repo.close();
}

test "Repo.open non-repo returns NotAGitRepo" {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.testing.expectError(error.NotAGitRepo, Repo.open(io, testing.allocator, "src"));
}

test "Repo.readGitFile HEAD" {
    var repo = try openFixture("tiny");
    defer repo.close();
    const head = try repo.readGitFileUnlimited("HEAD");
    defer testing.allocator.free(head);
    try std.testing.expect(std.mem.startsWith(u8, head, "ref: refs/heads/main"));
}

test "Repo.readGitFile missing returns NotFound" {
    var repo = try openFixture("tiny");
    defer repo.close();
    try std.testing.expectError(error.NotFound, repo.readGitFileUnlimited("nonexistent/file"));
}

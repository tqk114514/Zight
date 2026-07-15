//! 路径归一化与穿越防护。
//!
//! 所有来自用户输入或 git 对象内容的路径必须经 `validateRelative` 校验。
//! 拒绝 `..` 段、绝对路径、空字节、反斜杠（§5.1）。

const std = @import("std");

pub const MAX_PATH_LEN: usize = 4096;

pub const PathError = error{
    InvalidPath,
    PathTooLong,
    PathTraversal,
    AbsolutePath,
};

/// 校验相对路径的安全性。返回原切片以便直接使用。
///
/// 拒绝：空、空字节、反斜杠、绝对路径（`/` 或 `C:\`）、`..` 段、
/// 段为空（连续 `/` 或首尾 `/`）。
pub fn validateRelative(path: []const u8) PathError![]const u8 {
    if (path.len == 0 or path.len > MAX_PATH_LEN) {
        return if (path.len > MAX_PATH_LEN) error.PathTooLong else error.InvalidPath;
    }
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (path[0] == '/') return error.AbsolutePath;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) {
        return error.AbsolutePath;
    }
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, segment, "..")) return error.PathTraversal;
        if (std.mem.eql(u8, segment, ".")) return error.InvalidPath;
    }
    return path;
}

/// 安全拼接 `base` 与 `relative`（已通过 `validateRelative` 校验）。
/// 调用方拥有返回内存。
pub fn join(gpa: std.mem.Allocator, base: []const u8, relative: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, relative }) catch return error.OutOfMemory;
}

/// 校验 ref 名（§4.2）。ref 名使用 `/` 分隔，允许空段之间的合法段。
/// 拒绝：`..`、反斜杠、控制字符、空格、以 `-` 开头、以 `/` 结尾、含 `/.`。
pub fn validateRefName(name: []const u8) PathError!void {
    if (name.len == 0 or name.len > MAX_PATH_LEN) {
        return if (name.len > MAX_PATH_LEN) error.PathTooLong else error.InvalidPath;
    }
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.InvalidPath;
    if (name[0] == '-' or name[0] == '/' or name[0] == '.') return error.InvalidPath;
    if (name[name.len - 1] == '/' or name[name.len - 1] == '.') return error.InvalidPath;
    if (std.mem.eql(u8, name, "@")) return error.InvalidPath;
    if (std.mem.endsWith(u8, name, ".lock")) return error.InvalidPath;
    if (std.mem.indexOf(u8, name, "..") != null) return error.InvalidPath;
    if (std.mem.indexOf(u8, name, "/.") != null) return error.InvalidPath;

    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return error.InvalidPath;
        if (c == ' ' or c == '~' or c == '^' or c == ':' or c == '?' or c == '*' or c == '[' or c == '\\') {
            return error.InvalidPath;
        }
    }
}

test "validateRelative happy" {
    try std.testing.expectEqualStrings("src/foo.zig", try validateRelative("src/foo.zig"));
    try std.testing.expectEqualStrings("a/b/c", try validateRelative("a/b/c"));
}

test "validateRelative rejects traversal" {
    try std.testing.expectError(error.PathTraversal, validateRelative("../etc/passwd"));
    try std.testing.expectError(error.PathTraversal, validateRelative("a/../../b"));
    try std.testing.expectError(error.PathTraversal, validateRelative("a/../b"));
}

test "validateRelative rejects absolute and invalid" {
    try std.testing.expectError(error.AbsolutePath, validateRelative("/etc/passwd"));
    try std.testing.expectError(error.AbsolutePath, validateRelative("C:\\windows"));
    try std.testing.expectError(error.InvalidPath, validateRelative(""));
    try std.testing.expectError(error.InvalidPath, validateRelative("a\\b"));
    try std.testing.expectError(error.InvalidPath, validateRelative("a//b"));
    try std.testing.expectError(error.InvalidPath, validateRelative("a/"));
    try std.testing.expectError(error.InvalidPath, validateRelative("./a"));
}

test "validateRelative rejects null byte and too long" {
    try std.testing.expectError(error.InvalidPath, validateRelative("a\x00b"));
    var huge: [MAX_PATH_LEN + 1]u8 = undefined;
    @memset(&huge, 'a');
    try std.testing.expectError(error.PathTooLong, validateRelative(&huge));
}

test "validateRefName happy" {
    try validateRefName("refs/heads/main");
    try validateRefName("refs/tags/v1.0");
    try validateRefName("HEAD");
}

test "validateRefName rejects malformed" {
    try std.testing.expectError(error.InvalidPath, validateRefName(""));
    try std.testing.expectError(error.InvalidPath, validateRefName("-refs/heads/main"));
    try std.testing.expectError(error.InvalidPath, validateRefName("refs/heads/main/"));
    try std.testing.expectError(error.InvalidPath, validateRefName("refs/.. /mal"));
    try std.testing.expectError(error.InvalidPath, validateRefName("refs/heads/.main"));
    try std.testing.expectError(error.InvalidPath, validateRefName("refs/heads/main with space"));
    try std.testing.expectError(error.InvalidPath, validateRefName("refs\\heads\\main"));
}

test "validateRelative: 'a:b' should be valid relative path" {
    // 冒号在 git tree entry name 中合法；'a:b' 是相对路径，
    // 但 validateRelative 因 path[1]==':' 且 path[0] 为字母误判为 Windows 盘符绝对路径。
    try std.testing.expectEqualStrings("a:b", try validateRelative("a:b"));
}

test "validateRefName: rejects trailing dot" {
    // git refman: refname 不能以 '.' 结尾。
    try std.testing.expectError(error.InvalidPath, validateRefName("refs/heads/main."));
}

test "validateRefName: rejects leading dot (non './')" {
    // git refman: refname 不能以 '.' 开头。当前只拒绝 './' 前缀，
    // 漏掉了 '.hidden' 这类以 '.' 开头但第二字符非 '/' 的 ref 名。
    try std.testing.expectError(error.InvalidPath, validateRefName(".hidden"));
}

test "validateRefName: rejects single '@'" {
    // git refman: refname 不能是单独的 '@'（HEAD 的简写）。
    try std.testing.expectError(error.InvalidPath, validateRefName("@"));
}

test "validateRefName: rejects '.lock' suffix" {
    // git refman: refname 不能以 '.lock' 结尾（与 lock 文件冲突）。
    try std.testing.expectError(error.InvalidPath, validateRefName("refs/heads/foo.lock"));
}

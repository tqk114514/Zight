//! packfile v2 读取与 idx v2 索引。
//!
//! 职责（§2.4）：解析 `.git/objects/pack/*.pack` 与对应 `.idx`，
//! 按 oid 二分查找 offset，按 offset 读取 raw 对象（含 delta 引用信息）。
//! delta 解压（OFS_DELTA / REF_DELTA）由 `delta.zig` + `reader.zig` 协调。
//!
//! 完整性（§4.3）：open 时校验 packfile trailer SHA-1 与 idx 中的 packfile sha 一致；
//! idx 一次性 load 到内存（§6.2）；packfile 也全量 load（中小型仓库，§1.1）。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const hash = @import("hash.zig");
const Oid = hash.Oid;
const zlib = @import("zlib.zig");
const ZightError = @import("error.zig").ZightError;
const Repo = @import("repo.zig").Repo;
const Limits = @import("repo.zig").Limits;

pub const PackError = error{
    MalformedPack,
    MalformedIdx,
    CorruptedPack,
    CorruptedIdx,
    WrongPackVersion,
    WrongIdxVersion,
    NotFound,
    OutOfMemory,
    LimitExceeded,
    IoFailed,
    AccessDenied,
};

/// packfile 对象类型（3 bits）。
pub const PackObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

/// 读取到的 raw 对象（未解 delta）。
///
/// `data` 是 zlib 解压后的内容；对 delta 对象是 delta 指令流，对普通对象是 git 对象内容。
/// `base_offset` / `base_oid` 仅 delta 对象有效。调用方用 `deinit` 释放 `data`。
pub const RawObject = struct {
    type: PackObjectType,
    base_offset: ?u64,
    base_oid: ?Oid,
    data: []u8,

    pub fn deinit(self: *RawObject, gpa: Allocator) void {
        gpa.free(self.data);
        self.data = &.{};
    }

    pub fn isDelta(self: RawObject) bool {
        return self.type == .ofs_delta or self.type == .ref_delta;
    }
};

/// idx v2 解析视图（所有 slice 指向 `idx_data`，不独立拥有）。
const Idx = struct {
    count: u32,
    fanout: []const u8,
    shas: []const u8,
    offsets: []const u8,
    large_offsets: []const u8,
    pack_sha: [20]u8,
};

/// 单个 packfile + idx 句柄。
///
/// `pack_data` 与 `idx_data` 全量 load（owned）；`idx` 是其上的视图。
/// 调用方必须 `close` 释放。
pub const Pack = struct {
    allocator: Allocator,
    pack_data: []u8,
    idx_data: []u8,
    idx: Idx,
    count: u32,
    limits: Limits,

    /// 打开 `objects/pack/<pack_name>.pack` 与对应 `.idx`，校验完整性。
    pub fn open(repo: *Repo, pack_name: []const u8) PackError!Pack {
        const pack_data = try readPackFile(repo, pack_name);
        errdefer repo.allocator.free(pack_data);

        const count = try validatePackHeader(pack_data);
        try validatePackTrailer(pack_data);

        const idx_data = try readIdxFile(repo, pack_name);
        errdefer repo.allocator.free(idx_data);

        const idx = try parseIdx(idx_data, count);
        try validateIdxPackSha(&idx, pack_data);

        return .{
            .allocator = repo.allocator,
            .pack_data = pack_data,
            .idx_data = idx_data,
            .idx = idx,
            .count = count,
            .limits = repo.limits,
        };
    }

    pub fn close(self: *Pack) void {
        self.allocator.free(self.pack_data);
        self.allocator.free(self.idx_data);
    }

    pub fn hasObject(self: *const Pack, oid: Oid) bool {
        return self.findOffset(oid) != null;
    }

    /// 在 idx 中二分查找 `oid`，返回在 packfile 中的字节偏移；未找到返回 null。
    pub fn findOffset(self: *const Pack, oid: Oid) ?u64 {
        const b: usize = oid.bytes[0];
        const lo: u32 = if (b == 0) 0 else std.mem.readInt(u32, self.idx.fanout[(b - 1) * 4 ..][0..4], .big);
        const hi: u32 = std.mem.readInt(u32, self.idx.fanout[b * 4 ..][0..4], .big);
        if (hi <= lo) return null;

        var left: usize = lo;
        var right: usize = hi;
        while (left < right) {
            const mid = left + (right - left) / 2;
            const sha = self.idx.shas[mid * 20 ..][0..20];
            switch (std.mem.order(u8, sha, &oid.bytes)) {
                .eq => {
                    const off_raw = std.mem.readInt(u32, self.idx.offsets[mid * 4 ..][0..4], .big);
                    if (off_raw & 0x80000000 != 0) {
                        const large_idx = off_raw & 0x7fffffff;
                        if (large_idx * 8 + 8 > self.idx.large_offsets.len) return null;
                        return std.mem.readInt(u64, self.idx.large_offsets[large_idx * 8 ..][0..8], .big);
                    }
                    return off_raw & 0x7fffffff;
                },
                .lt => left = mid + 1,
                .gt => right = mid,
            }
        }
        return null;
    }

    /// 读取 offset 处的 raw 对象（不解 delta）。调用方拥有返回内存。
    pub fn readRaw(self: *Pack, allocator: Allocator, offset: u64) PackError!RawObject {
        if (offset >= self.pack_data.len) return error.MalformedPack;
        var pos: usize = @intCast(offset);

        const header_byte = self.pack_data[pos];
        pos += 1;
        const type_raw: u3 = @intCast((header_byte >> 4) & 0x07);
        const obj_type: PackObjectType = switch (type_raw) {
            1 => .commit,
            2 => .tree,
            3 => .blob,
            4 => .tag,
            6 => .ofs_delta,
            7 => .ref_delta,
            else => return error.MalformedPack,
        };

        var size: u64 = header_byte & 0x0f;
        var shift: u6 = 4;
        var c = header_byte;
        while (c & 0x80 != 0) {
            if (pos >= self.pack_data.len) return error.MalformedPack;
            if (shift > 56) return error.MalformedPack;
            c = self.pack_data[pos];
            pos += 1;
            size |= @as(u64, c & 0x7f) << shift;
            shift += 7;
        }

        if (size > self.limits.packfile_object_max) return error.LimitExceeded;

        var base_offset: ?u64 = null;
        var base_oid: ?Oid = null;

        switch (obj_type) {
            .ofs_delta => {
                if (pos >= self.pack_data.len) return error.MalformedPack;
                var oc = self.pack_data[pos];
                pos += 1;
                var off: u64 = oc & 0x7f;
                while (oc & 0x80 != 0) {
                    off += 1;
                    if (pos >= self.pack_data.len) return error.MalformedPack;
                    oc = self.pack_data[pos];
                    pos += 1;
                    off = (off << 7) | (oc & 0x7f);
                }
                if (off > offset) return error.MalformedPack;
                base_offset = offset - off;
            },
            .ref_delta => {
                if (pos + 20 > self.pack_data.len) return error.MalformedPack;
                var oid: Oid = .{ .bytes = undefined };
                @memcpy(&oid.bytes, self.pack_data[pos..][0..20]);
                base_oid = oid;
                pos += 20;
            },
            else => {},
        }

        const compressed = self.pack_data[pos..];
        // .limited(n) 在恰好读到 n 字节时报 StreamTooLong（"reached or exceeded"），
        // 故用 size+1；解压后校验 data.len == size 以发现实际大小与声明不符的损坏。
        const data = zlib.decompress(allocator, compressed, .limited(@intCast(size + 1))) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.LimitExceeded,
            else => return error.CorruptedPack,
        };
        errdefer allocator.free(data);
        if (data.len != size) return error.CorruptedPack;

        return .{
            .type = obj_type,
            .base_offset = base_offset,
            .base_oid = base_oid,
            .data = data,
        };
    }
};

fn readPackFile(repo: *Repo, pack_name: []const u8) PackError![]u8 {
    const path = std.fmt.allocPrint(repo.allocator, "objects/pack/{s}.pack", .{pack_name}) catch return error.OutOfMemory;
    defer repo.allocator.free(path);
    return repo.readGitFile(path, .limited(repo.limits.packfile_max)) catch |err| switch (err) {
        error.NotFound => error.NotFound,
        error.StreamTooLong => error.LimitExceeded,
        error.AccessDenied => error.AccessDenied,
        else => error.IoFailed,
    };
}

fn readIdxFile(repo: *Repo, pack_name: []const u8) PackError![]u8 {
    const path = std.fmt.allocPrint(repo.allocator, "objects/pack/{s}.idx", .{pack_name}) catch return error.OutOfMemory;
    defer repo.allocator.free(path);
    return repo.readGitFile(path, .limited(repo.limits.index_file_max)) catch |err| switch (err) {
        error.NotFound => error.NotFound,
        error.StreamTooLong => error.LimitExceeded,
        error.AccessDenied => error.AccessDenied,
        else => error.IoFailed,
    };
}

fn validatePackHeader(data: []const u8) PackError!u32 {
    if (data.len < 32) return error.MalformedPack;
    if (!std.mem.eql(u8, data[0..4], "PACK")) return error.MalformedPack;
    const version = std.mem.readInt(u32, data[4..8], .big);
    if (version != 2) return error.WrongPackVersion;
    return std.mem.readInt(u32, data[8..12], .big);
}

fn validatePackTrailer(data: []const u8) PackError!void {
    if (data.len < 32) return error.MalformedPack;
    const expected = data[data.len - 20 ..][0..20];
    var actual: [20]u8 = undefined;
    hash.sha1(data[0 .. data.len - 20], &actual);
    if (!std.mem.eql(u8, &actual, expected)) return error.CorruptedPack;
}

fn parseIdx(data: []const u8, pack_count: u32) PackError!Idx {
    if (data.len < 8) return error.MalformedIdx;
    if (!std.mem.eql(u8, data[0..4], "\xfftOc")) return error.MalformedIdx;
    const version = std.mem.readInt(u32, data[4..8], .big);
    if (version != 2) return error.WrongIdxVersion;

    const count: usize = pack_count;
    const fanout_end = 8 + 256 * 4;
    const shas_end = fanout_end + count * 20;
    const crc_end = shas_end + count * 4;
    const offsets_end = crc_end + count * 4;
    if (data.len < offsets_end + 40) return error.MalformedIdx;

    // idx 末尾：pack_sha(20) + idx_sha(20)
    const large_offsets_end = data.len - 40;
    const large_offsets = if (large_offsets_end > offsets_end) data[offsets_end..large_offsets_end] else &[_]u8{};

    // fanout[255] 必须等于 pack_count
    const fanout_count = std.mem.readInt(u32, data[fanout_end - 4 ..][0..4], .big);
    if (fanout_count != pack_count) return error.CorruptedIdx;

    return .{
        .count = pack_count,
        .fanout = data[8..fanout_end],
        .shas = data[fanout_end..shas_end],
        .offsets = data[crc_end..offsets_end],
        .large_offsets = large_offsets,
        .pack_sha = data[data.len - 40 ..][0..20].*,
    };
}

fn validateIdxPackSha(idx: *const Idx, pack_data: []const u8) PackError!void {
    const trailer = pack_data[pack_data.len - 20 ..][0..20];
    if (!std.mem.eql(u8, &idx.pack_sha, trailer)) return error.CorruptedIdx;
}

const testing = std.testing;

fn openFixture(name: []const u8) !Repo {
    const path = try std.fmt.allocPrint(testing.allocator, "test/fixtures/{s}", .{name});
    defer testing.allocator.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    return Repo.open(io, testing.allocator, path);
}

/// 枚举 `objects/pack` 下的 pack 基名（不含路径与 `.pack`/`.idx` 后缀）。
/// 返回第一个匹配的 pack 名；用于测试。调用方拥有返回内存。
fn firstPackName(repo: *Repo) ![]u8 {
    var pack_dir = repo.git_dir.openDir(repo.io, "objects/pack", .{ .access_sub_paths = false, .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return error.IoFailed,
    };
    defer pack_dir.close(repo.io);
    var it = pack_dir.iterate();
    while (try it.next(repo.io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".idx")) {
            return testing.allocator.dupe(u8, entry.name[0 .. entry.name.len - 4]);
        }
    }
    return error.NotFound;
}

fn headOid(repo: *Repo) !Oid {
    const head = try repo.readGitFileUnlimited("HEAD");
    defer testing.allocator.free(head);
    const trimmed = std.mem.trimEnd(u8, head, " \t\r\n");
    const ref_name = trimmed["ref: ".len..];
    const oid_hex = try repo.readGitFileUnlimited(ref_name);
    defer testing.allocator.free(oid_hex);
    const t = std.mem.trimEnd(u8, oid_hex, " \t\r\n");
    return Oid.fromHex(t) catch error.MalformedRef;
}

test "Pack.open packed fixture (OFS_DELTA)" {
    var repo = try openFixture("packed");
    defer repo.close();
    const pack_name = try firstPackName(&repo);
    defer testing.allocator.free(pack_name);

    var pack = try Pack.open(&repo, pack_name);
    defer pack.close();

    const oid = try headOid(&repo);
    try testing.expect(pack.hasObject(oid));
    const offset = pack.findOffset(oid).?;
    try testing.expect(offset > 0);
}

test "Pack.readRaw commit object" {
    var repo = try openFixture("packed");
    defer repo.close();
    const pack_name = try firstPackName(&repo);
    defer testing.allocator.free(pack_name);

    var pack = try Pack.open(&repo, pack_name);
    defer pack.close();

    const oid = try headOid(&repo);
    const offset = pack.findOffset(oid).?;
    var raw = try pack.readRaw(testing.allocator, offset);
    defer raw.deinit(testing.allocator);

    try testing.expectEqual(PackObjectType.commit, raw.type);
    try testing.expect(!raw.isDelta());
    try testing.expect(raw.base_offset == null);
    try testing.expect(raw.base_oid == null);
    try testing.expect(std.mem.startsWith(u8, raw.data, "tree "));
}

test "Pack.readRaw finds delta object" {
    var repo = try openFixture("packed");
    defer repo.close();
    const pack_name = try firstPackName(&repo);
    defer testing.allocator.free(pack_name);

    var pack = try Pack.open(&repo, pack_name);
    defer pack.close();

    // 遍历 idx 所有对象，至少有一个 OFS_DELTA
    var found_delta = false;
    var i: usize = 0;
    while (i < pack.count) : (i += 1) {
        var sha: [20]u8 = undefined;
        @memcpy(&sha, pack.idx.shas[i * 20 ..][0..20]);
        const oid = Oid{ .bytes = sha };
        const offset = pack.findOffset(oid).?;
        var raw = try pack.readRaw(testing.allocator, offset);
        defer raw.deinit(testing.allocator);
        if (raw.type == .ofs_delta) {
            found_delta = true;
            try testing.expect(raw.base_offset != null);
            break;
        }
    }
    try testing.expect(found_delta);
}

test "Pack.open REF_DELTA fixture" {
    var repo = try openFixture("packed-ref");
    defer repo.close();
    const pack_name = try firstPackName(&repo);
    defer testing.allocator.free(pack_name);

    var pack = try Pack.open(&repo, pack_name);
    defer pack.close();

    var found_ref_delta = false;
    var i: usize = 0;
    while (i < pack.count) : (i += 1) {
        var sha: [20]u8 = undefined;
        @memcpy(&sha, pack.idx.shas[i * 20 ..][0..20]);
        const oid = Oid{ .bytes = sha };
        const offset = pack.findOffset(oid).?;
        var raw = try pack.readRaw(testing.allocator, offset);
        defer raw.deinit(testing.allocator);
        if (raw.type == .ref_delta) {
            found_ref_delta = true;
            try testing.expect(raw.base_oid != null);
            break;
        }
    }
    try testing.expect(found_ref_delta);
}

test "Pack.findOffset missing returns null" {
    var repo = try openFixture("packed");
    defer repo.close();
    const pack_name = try firstPackName(&repo);
    defer testing.allocator.free(pack_name);

    var pack = try Pack.open(&repo, pack_name);
    defer pack.close();

    const zero = Oid.fromHex("0000000000000000000000000000000000000000") catch unreachable;
    try testing.expect(!pack.hasObject(zero));
    try testing.expect(pack.findOffset(zero) == null);
}

test "Pack.open missing pack returns NotFound" {
    var repo = try openFixture("packed");
    defer repo.close();
    try testing.expectError(error.NotFound, Pack.open(&repo, "pack-nonexistent"));
}

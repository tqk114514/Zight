//! Zight：用 Zig 编写的 git 仓库只读解析库。
//!
//! 所有公共符号从此处 re-export（§7.1）。v1 之前 API 不保证稳定。

pub const ZightError = @import("error.zig").ZightError;
pub const IoError = @import("error.zig").IoError;
pub const hash = @import("hash.zig");
pub const path = @import("path.zig");
pub const zlib = @import("zlib.zig");
pub const Repo = @import("repo.zig").Repo;
pub const Limits = @import("repo.zig").Limits;
pub const object = @import("object.zig");
pub const ObjectType = @import("object.zig").ObjectType;
pub const Object = @import("object.zig").Object;
pub const ref = @import("ref.zig");
pub const Ref = @import("ref.zig").Ref;
pub const pack = @import("pack.zig");
pub const Pack = @import("pack.zig").Pack;
pub const PackObjectType = @import("pack.zig").PackObjectType;
pub const RawObject = @import("pack.zig").RawObject;
pub const delta = @import("delta.zig");
pub const applyDelta = @import("delta.zig").applyDelta;
pub const reader = @import("reader.zig");
pub const Reader = @import("reader.zig").Reader;
pub const log = @import("log.zig");
pub const Log = @import("log.zig").Log;
pub const LogEntry = @import("log.zig").LogEntry;
pub const tree_browse = @import("tree_browse.zig");
pub const TreeWalker = @import("tree_browse.zig").TreeWalker;
pub const TreeMode = @import("tree_browse.zig").TreeMode;
pub const WalkEntry = @import("tree_browse.zig").WalkEntry;
pub const line_diff = @import("line_diff.zig");
pub const DiffOp = @import("line_diff.zig").DiffOp;
pub const DiffOpType = @import("line_diff.zig").Op;
pub const diff = @import("diff.zig");
pub const TreeDiff = @import("diff.zig").TreeDiff;
pub const FileChange = @import("diff.zig").FileChange;
pub const ChangeKind = @import("diff.zig").ChangeKind;
pub const diffBlobLines = @import("diff.zig").diffBlobLines;
pub const blame = @import("blame.zig");
pub const Blame = @import("blame.zig").Blame;
pub const blameAt = @import("blame.zig").blameAt;
pub const bloom = @import("bloom.zig");
pub const Bloom = @import("bloom.zig").Bloom;
pub const index = @import("index.zig");
pub const Index = @import("index.zig").Index;
pub const CommitRecord = @import("index.zig").CommitRecord;

test {
    _ = @import("error.zig");
    _ = @import("hash.zig");
    _ = @import("path.zig");
    _ = @import("zlib.zig");
    _ = @import("repo.zig");
    _ = @import("object.zig");
    _ = @import("ref.zig");
    _ = @import("pack.zig");
    _ = @import("delta.zig");
    _ = @import("reader.zig");
    _ = @import("log.zig");
    _ = @import("tree_browse.zig");
    _ = @import("line_diff.zig");
    _ = @import("diff.zig");
    _ = @import("blame.zig");
    _ = @import("bloom.zig");
    _ = @import("index.zig");
}

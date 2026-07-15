//! 跨模块公共错误集。
//!
//! 各模块自有错误集命名 `<Module>Error`；跨模块的语义错误集中于此。

const PathError = @import("path.zig").PathError;

/// Zight 公共错误。所有面向调用方的 API 返回此错误集或其子集。
pub const ZightError = error{
    NotAGitRepo,
    CorruptedObject,
    MalformedObject,
    MalformedRef,
    SymrefTooDeep,
    LimitExceeded,
    OutOfMemory,
} || PathError || IoError;

/// 底层 I/O 错误（读文件失败等）。
pub const IoError = error{
    IoFailed,
    NotFound,
    AccessDenied,
    StreamTooLong,
};

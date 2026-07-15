# Zight

> Zight = Zig + Sight，用 Zig 的眼光看 Git。

用 Zig 0.16.0 编写的 git 仓库**只读**解析库。形态为嵌入式库，被其它 Zig / Go / Node 程序链接调用。不含 HTTP 服务、前端、网络协议与任何写操作。

## 能力

- loose 对象读取：blob / tree / commit / tag（zlib 压缩，SHA-1 校验）
- packfile v2 解析：含 OFS_DELTA（type 6）与 REF_DELTA（type 7），idx v2 索引
- ref 解析：loose refs / packed-refs / HEAD / symref 链（深度上限 5）
- commit 历史遍历：优先队列按 committer time 降序，流式产出，支持分页
- diff：文件级 tree diff（栈式递归）+ 行级 Myers O(ND)
- blame：全历史行级追溯（可选索引加速）
- 文件树浏览：栈式递归遍历 tree，流式产出

所有列举类 API 返回迭代器而非 `[]T`，面向 Linux 内核级超大仓库设计。

## 构建

```sh
zig build            # 构建库
zig build test       # 运行测试
```

测试 fixture 在 `test/fixtures/`，由 `test/fixtures/gen.sh` 幂等重建（需本地有 `git`）：

```sh
bash test/fixtures/gen.sh
```

## 依赖

- Zig 0.16.0
- 零第三方依赖，仅使用 `std`

## 使用

通过 `build.zig.zon` 作为依赖引入，所有公共符号从 `zight` 模块的 `lib.zig` re-export。v1 之前 API 不保证稳定。

blame 可选启用索引加速：调用方用 `Index.open(&repo)` 取索引，传给 `blameFile`。首次访问时若索引不存在，调用 `Index.build` 构建并写入 `.zight/index`；索引头存 ref tip digest，ref tip 变化时 `open` 返回 null 自动触发重建。无索引时 `blameFile` 回退到实时解析，功能等价。

## 许可证

MIT

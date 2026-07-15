#!/usr/bin/env bash
# 生成 test/fixtures 下测试用 git 仓库。幂等：先删后建。详见 rule.md §8.2。
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[ "$SCRIPT_DIR" = "${BASH_SOURCE[0]}" ] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

# --- tiny：loose 对象 fixture ---
FIXTURE="$SCRIPT_DIR/tiny"
rm -rf "$FIXTURE"
mkdir -p "$FIXTURE"
cd "$FIXTURE"
git init -q -b main
git config user.email "test@zight.local"
git config user.name "Zight Test"
git config commit.gpgsign false
git config core.autocrlf false

printf "hello zight\n" > README.md
git add README.md
git commit -q -m "initial"

mkdir -p src
printf "nested file\n" > src/nested.txt
git add src/nested.txt
git commit -q -m "add nested"

git tag -a v1.0 -m "release v1.0"
rm -rf .git/hooks

# --- packed：OFS_DELTA / REF_DELTA fixture ---
build_packed() {
    local fixture="$1"
    local use_dbo="$2" # true → OFS_DELTA；false → REF_DELTA
    rm -rf "$fixture"
    mkdir -p "$fixture"
    cd "$fixture"
    git init -q -b main
    git config user.email "test@zight.local"
    git config user.name "Zight Test"
    git config commit.gpgsign false
    git config core.autocrlf false

    printf "base line %s\n" {1..20} > data.txt
    git add data.txt
    git commit -q -m "v1"
    sed -i 's/^base line 10$/modified line 10/' data.txt
    git add data.txt
    git commit -q -m "v2"
    sed -i 's/^base line 15$/modified line 15/' data.txt
    git add data.txt
    git commit -q -m "v3"
    printf "standalone\n" > other.txt
    git add other.txt
    git commit -q -m "add other"

    if [ "$use_dbo" = "true" ]; then
        git repack -a -d -f
    else
        # git for Windows 2.55.0 忽略 -c pack.useDeltaBaseOffset=false，
        # 必须用 pack-objects --no-delta-base-offset 强制 REF_DELTA。
        git rev-list --all --objects | \
            git pack-objects --no-delta-base-offset .git/objects/pack/pack >/dev/null
        # 删除已入 pack 的 loose 对象
        find .git/objects -type f ! -path '*/pack/*' ! -path '*/info/*' -delete
        find .git/objects -type d -empty -delete
    fi
    rm -rf .git/hooks
}

build_packed "$SCRIPT_DIR/packed" "true"
build_packed "$SCRIPT_DIR/packed-ref" "false"

# --- merge：多分支 + merge commit fixture ---
FIXTURE="$SCRIPT_DIR/merge"
rm -rf "$FIXTURE"
mkdir -p "$FIXTURE"
cd "$FIXTURE"
git init -q -b main
git config user.email "test@zight.local"
git config user.name "Zight Test"
git config commit.gpgsign false
git config core.autocrlf false

printf "base\n" > base.txt
git add base.txt
git commit -q -m "base"

printf "main1\n" > main1.txt
git add main1.txt
git commit -q -m "main1"

git checkout -q -b feature
printf "feat1\n" > feat1.txt
git add feat1.txt
git commit -q -m "feat1"

git checkout -q main
printf "main2\n" > main2.txt
git add main2.txt
git commit -q -m "main2"

git merge -q --no-ff feature -m "merge feature"

# octopus merge（3-parent）用于 index edge list 测试
git checkout -q -b branchB
printf "b1\n" > b1.txt
git add b1.txt
git commit -q -m "branchB commit"

git checkout -q main
git checkout -q -b branchC
printf "c1\n" > c1.txt
git add c1.txt
git commit -q -m "branchC commit"

git checkout -q main
git merge -q --no-ff branchB branchC -m "octopus merge branchB and branchC"

# Index.build 假设仓库已 git gc（plan §2），merge fixture 需有 packfile。
git repack -a -d
rm -rf .git/hooks

# --- empty：空仓库 fixture（无 commit、无 ref） ---
FIXTURE="$SCRIPT_DIR/empty"
rm -rf "$FIXTURE"
mkdir -p "$FIXTURE"
cd "$FIXTURE"
git init -q -b main
git config core.autocrlf false
rm -rf .git/hooks

# --- edge：边缘情况 fixture ---
# 覆盖：深嵌套 tree、空子目录、空文件、单行文件、整文件重写、
#       类型变更（blob→tree 同名）、超深 symref 链（depth > 5）。
FIXTURE="$SCRIPT_DIR/edge"
rm -rf "$FIXTURE"
mkdir -p "$FIXTURE"
cd "$FIXTURE"
git init -q -b main
git config user.email "test@zight.local"
git config user.name "Zight Test"
git config commit.gpgsign false
git config core.autocrlf false

# 空文件 + 单行文件 + 深嵌套（8 层）+ 空子目录（.gitkeep）
printf "" > empty.txt
printf "only line\n" > oneline.txt
mkdir -p a/b/c/d/e/f/g/h
printf "deep leaf\n" > a/b/c/d/e/f/g/h/leaf.txt
mkdir -p empty_dir
printf "" > empty_dir/.gitkeep
git add .
git commit -q -m "init edge"

# 整文件重写：a/b/c → x/y/z
printf "a\nb\nc\n" > rewrite.txt
git add rewrite.txt
git commit -q -m "add rewrite"
printf "x\ny\nz\n" > rewrite.txt
git add rewrite.txt
git commit -q -m "rewrite all"

# 类型变更：foo 从 blob 变 tree
printf "foo as blob\n" > foo
git add foo
git commit -q -m "foo as blob"
git rm -q foo
mkdir foo
printf "foo as tree\n" > foo/child.txt
git add foo
git commit -q -m "foo as tree"

# 超深 symref 链：refs/chain/a → b → c → d → e → f → g → oid（6 层 symref）
# 从 refs/chain/a 解析在 depth 6 触发 SymrefTooDeep（max_symref_depth = 5）。
HEAD_OID=$(git rev-parse HEAD)
mkdir -p .git/refs/chain
printf "ref: refs/chain/b\n" > .git/refs/chain/a
printf "ref: refs/chain/c\n" > .git/refs/chain/b
printf "ref: refs/chain/d\n" > .git/refs/chain/c
printf "ref: refs/chain/e\n" > .git/refs/chain/d
printf "ref: refs/chain/f\n" > .git/refs/chain/e
printf "ref: refs/chain/g\n" > .git/refs/chain/f
printf "%s\n" "$HEAD_OID" > .git/refs/chain/g

rm -rf .git/hooks

# --- malformed：畸形 loose 对象 fixture（reader pub API 切片越界 panic 复现）---
FIXTURE="$SCRIPT_DIR/malformed"
rm -rf "$FIXTURE"
mkdir -p "$FIXTURE"
cd "$FIXTURE"
git init -q -b main
git config core.autocrlf false
rm -rf .git/hooks

# git hash-object --literally 绕过 fsck，只做 zlib 压缩 + hash + 存储，
# 用来构造 hash 校验通过但内容畸形的 loose 对象。
# 畸形 commit content="tree abc"（行长 8 < 45，触发 commitTree 切片越界）
printf "tree abc" | git hash-object --literally -t commit -w --stdin >/dev/null
# 畸形 commit content="parent abc"（行长 10 < 47，触发 firstParent 切片越界）
printf "parent abc" | git hash-object --literally -t commit -w --stdin >/dev/null
# 畸形 tag content="object abc"（行长 10 < 47，触发 peelToCommit 切片越界）
printf "object abc" | git hash-object --literally -t tag -w --stdin >/dev/null

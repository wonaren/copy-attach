#!/usr/bin/env bash
#
# check_push.sh — 提交/推送前版本发布一致性检查
#
# 开发习惯（与 CLAUDE.md 版本号约定一致）：
#   开发中：Cargo.toml 版本带 -dev 后缀（如 0.99.27-dev），CHANGELOG 变更写在 [Unreleased] 下
#   发布前：去掉 -dev 后缀，并把 [Unreleased] 内容整理为「## [X.Y.Z] - YYYY-MM-DD」章节
#
# 检查项：
#   1. Cargo.toml 版本号为干净的 X.Y.Z（-dev 后缀已去掉）
#   2. Cargo.lock 根包版本与 Cargo.toml 一致（bump 后需跑过 cargo check / build）
#   3. SwiftApp/Info.plist 的 CFBundleShortVersionString 与 Cargo.toml 一致（build.sh 会写入源码 plist，未重新构建时会残留旧版本）
#   4. CHANGELOG.md 有「## [X.Y.Z] - 日期」章节，且位于最顶部
#   5. [Unreleased] 章节为空（开发条目已全部移入发布章节）
#   6. 章节日期合法且不晚于今天
#   7. 版本相对上一发布章节不倒退、不重复
#   8. 同版本章节不重复出现（CI 按版本号提取 Release Notes）
#   9. 已存在同版本 git tag 时告警
#
# 任一检查失败退出码为 1，可直接挂在 pre-push hook：
#   .git/hooks/pre-push  →  bash check_push.sh
#
# 用法：bash check_push.sh

set -euo pipefail
cd "$(dirname "$0")"

# ---------- 输出 ----------
FAILED=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=''; C_YEL=''; C_GRN=''; C_DIM=''; C_RST=''
fi
fail() { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RST"; FAILED=1; }
warn() { printf '%s! %s%s\n' "$C_YEL" "$*" "$C_RST"; }
ok()   { printf '%s✓ %s%s\n' "$C_GRN" "$*" "$C_RST"; }

# 点分数字版本比较：输出 1(a>b) / 0(a==b) / -1(a<b)
ver_cmp() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    split(a, A, "."); split(b, B, ".");
    for (i = 1; i <= 3; i++) { A[i] += 0; B[i] += 0; }
    for (i = 1; i <= 3; i++) {
      if (A[i] < B[i]) { print -1; exit }
      if (A[i] > B[i]) { print 1; exit }
    }
    print 0;
  }'
}

summary() {
  echo
  if [[ "${FAILED}" -eq 0 ]]; then
    echo "${C_GRN}全部检查通过，可以提交 / 推送 ✓${C_RST}"
  else
    echo "${C_RED}${FAILED} 项检查未通过——请修复后再提交${C_RST}"
  fi
  exit "${FAILED}"
}

# ---------- 1. 版本 ----------
if [[ ! -f Cargo.toml ]]; then
  echo "${C_RED}✗ 找不到 Cargo.toml（请在仓库根目录运行）${C_RST}"
  exit 1
fi
VERSION=$(sed -n 's/^version = "\([^"]*\)".*/\1/p' Cargo.toml | head -1)
if [[ -z "${VERSION}" ]]; then
  fail "Cargo.toml 中读取不到 version"
  summary
fi
echo "${C_DIM}当前版本：${VERSION}${C_RST}"

DEV_MODE=0
if [[ "${VERSION}" == *-dev ]]; then
  fail "版本号仍带 -dev 后缀（${VERSION}）——发布前请去掉后缀，如 0.99.27-dev → 0.99.27"
  DEV_MODE=1
elif [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "版本号不是预期的 X.Y.Z / X.Y.Z-dev 形态：${VERSION}"
  DEV_MODE=1
else
  ok "版本号已是干净的发布版本：${VERSION}"
fi

# ---------- 2. Cargo.lock 同步 ----------
if [[ -f Cargo.lock ]]; then
  LOCK_VERSION=$(awk '/^name = "copy-attach"/{getline; print; exit}' Cargo.lock | sed 's/^version = "\([^"]*\)".*/\1/')
  if [[ -z "${LOCK_VERSION}" ]]; then
    warn "Cargo.lock 中找不到根包 copy-attach 的版本（无法校验）"
  elif [[ "${LOCK_VERSION}" != "${VERSION}" ]]; then
    fail "Cargo.lock 版本（${LOCK_VERSION}）与 Cargo.toml（${VERSION}）不一致——bump 后需执行 cargo check / cargo build 刷新 lockfile"
  else
    ok "Cargo.lock 版本一致（${LOCK_VERSION}）"
  fi
fi

# ---------- 3. SwiftApp/Info.plist 同步 ----------
if [[ -f SwiftApp/Info.plist ]]; then
  PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" SwiftApp/Info.plist 2>/dev/null || true)
  if [[ -z "${PLIST_VERSION}" ]]; then
    warn "SwiftApp/Info.plist 中读不到 CFBundleShortVersionString（无法校验）"
  elif [[ "${PLIST_VERSION}" != "${VERSION}" ]]; then
    fail "SwiftApp/Info.plist 版本（${PLIST_VERSION}）与 Cargo.toml（${VERSION}）不一致——请执行 ./build.sh 同步，或手动 PlistBuddy 更新"
  else
    ok "SwiftApp/Info.plist 版本一致（${PLIST_VERSION}）"
  fi
fi

if [[ "${DEV_MODE}" -eq 1 ]]; then
  echo
  echo "${C_YEL}版本仍处于 -dev 开发态，跳过 CHANGELOG 发布章节检查（Unreleased 有内容属正常）${C_RST}"
  summary
fi

# ---------- 4. CHANGELOG 发布章节 ----------
if [[ ! -f CHANGELOG.md ]]; then
  fail "缺少 CHANGELOG.md"
  summary
fi

# 形如「## [X.Y.Z] - YYYY-MM-DD」的章节（按出现顺序）
SECTIONS=()
while IFS= read -r line; do SECTIONS+=("$line"); done \
  < <(grep -nE '^## \[[0-9]+\.[0-9]+\.[0-9]+\] - [0-9]{4}-[0-9]{2}-[0-9]{2}' CHANGELOG.md || true)

VERSION_HEADING=$(grep -nF "## [${VERSION}]" CHANGELOG.md | head -1 || true)
VERSION_HEADING_TEXT=""
if [[ -n "${VERSION_HEADING}" ]]; then
  VERSION_HEADING_TEXT=$(sed -E 's/^[0-9]+://' <<< "${VERSION_HEADING}")
fi
if [[ -z "${VERSION_HEADING_TEXT}" ]]; then
  fail "CHANGELOG.md 中没有「## [${VERSION}]」章节——请把 [Unreleased] 内容整理为「## [${VERSION}] - 日期」"
else
  ok "找到版本章节：${VERSION_HEADING_TEXT}"
fi

# 最顶部的发布章节必须是当前版本
if [[ ${#SECTIONS[@]} -gt 0 ]]; then
  FIRST_DATED=$(sed -E 's/^[0-9]+:## \[([^]]+)\] - .*/\1/' <<< "${SECTIONS[0]}")
  if [[ "${FIRST_DATED}" != "${VERSION}" ]]; then
    fail "CHANGELOG 最顶部的发布章节是 ${FIRST_DATED}，不是 ${VERSION}——本次发布章节应放在最上面"
  else
    ok "发布章节位于 CHANGELOG 最顶部"
  fi
fi

# 章节日期（macOS date 会把非法日期静默归一化，需做 round-trip 校验）
SECTION_DATE=""
[[ "${VERSION_HEADING_TEXT}" =~ -[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}) ]] && SECTION_DATE="${BASH_REMATCH[1]}"
if [[ -z "${VERSION_HEADING_TEXT}" ]]; then
  : # 缺章节已在上方报错，不再重复
elif [[ -z "${SECTION_DATE}" ]]; then
  fail "版本章节缺少日期或格式不对——应为「## [${VERSION}] - YYYY-MM-DD」（实际：${VERSION_HEADING_TEXT}）"
else
  ROUNDTRIP=$(date -j -f '%Y-%m-%d' "${SECTION_DATE}" +%Y-%m-%d 2>/dev/null || true)
  TODAY=$(date +%Y-%m-%d)
  if [[ "${ROUNDTRIP}" != "${SECTION_DATE}" ]]; then
    fail "章节日期「${SECTION_DATE}」不是合法日期（macOS date 会把 2 月 31 日之类静默归一化，需原样回显）"
  elif [[ "${SECTION_DATE}" > "${TODAY}" ]]; then
    fail "章节日期「${SECTION_DATE}」晚于今天（${TODAY}）——发布章节日期应为当天"
  else
    ok "章节日期合法：${SECTION_DATE}"
  fi
fi

# 版本相对上一发布不倒退 / 不重复
if [[ ${#SECTIONS[@]} -ge 2 ]]; then
  PREV_VER=$(sed -E 's/^[0-9]+:## \[([^]]+)\] - .*/\1/' <<< "${SECTIONS[1]}")
  CMP=$(ver_cmp "${VERSION}" "${PREV_VER}")
  if [[ "${CMP}" == "-1" ]]; then
    fail "版本号倒退：当前 ${VERSION} < 上一发布 ${PREV_VER}"
  elif [[ "${CMP}" == "0" ]]; then
    warn "当前版本 ${VERSION} 与上一发布章节相同（重复发布请确认）"
  else
    ok "版本高于上一发布（${PREV_VER}）"
  fi
fi

# 同版本章节重复
MATCH_COUNT=$(grep -cF "## [${VERSION}]" CHANGELOG.md || true)
if [[ "${MATCH_COUNT}" -gt 1 ]]; then
  warn "「## [${VERSION}]」章节出现 ${MATCH_COUNT} 次——CI 按版本提取 Release Notes 会取错，请只保留一个"
fi

# 发布章节没有内容
if [[ -n "${VERSION_HEADING_TEXT}" ]] && \
   awk -v h="${VERSION_HEADING_TEXT}" 'index($0,h){f=1;next} f&&/^## \[/{exit 0} f&&NF{exit 1}' CHANGELOG.md; then
  warn "发布章节「${VERSION_HEADING_TEXT}」没有内容"
fi

# ---------- 5. [Unreleased] 必须为空 ----------
UNRELEASED_LINES=$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f&&NF{n++} END{print n+0}' CHANGELOG.md)
if [[ "${UNRELEASED_LINES}" -gt 0 ]]; then
  fail "[Unreleased] 章节仍有 ${UNRELEASED_LINES} 行未整理内容——请全部移入「## [${VERSION}]」发布章节"
else
  ok "[Unreleased] 章节为空（或不存在），无遗漏条目"
fi

# ---------- 6. git tag ----------
if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null 2>&1; then
  warn "已存在 tag v${VERSION}——推送标签会冲突，请确认是否要重复发布"
else
  ok "无同版本 git tag（v${VERSION}）"
fi

summary

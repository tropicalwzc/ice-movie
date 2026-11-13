#!/bin/bash
# 拉取固定版本的播放器三方源码，并应用本仓库维护的 patch。
#
# 父仓库不再记录 Vendor/AMSMB2 与 Vendor/ffmpeg/ffmpeg-src 的 gitlink，
# 换机器/CI 时执行本脚本即可得到可复现的源码树：
#   ./Vendor/setup.sh
#
# 脚本是幂等的：目录已存在且版本正确时不会重新 clone。
# 如果目录里有本地修改，脚本不会强制 reset；会明确报错，交由开发者处理。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"

FFMPEG_URL="${FFMPEG_URL:-https://gitee.com/mirrors/ffmpeg.git}"
FFMPEG_REF="${FFMPEG_REF:-release/7.1}"
FFMPEG_COMMIT="${FFMPEG_COMMIT:-f9db090b14c255a8f1c5f8f41a4c92b723228763}"

AMSMB2_URL="${AMSMB2_URL:-https://github.com/amosavian/AMSMB2.git}"
AMSMB2_REF="${AMSMB2_REF:-4.0.3}"
AMSMB2_COMMIT="${AMSMB2_COMMIT:-1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0}"

LIBSMB2_URL="${LIBSMB2_URL:-https://github.com/sahlberg/libsmb2.git}"
LIBSMB2_COMMIT="${LIBSMB2_COMMIT:-aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03}"

patch_reverse_check() {
  local repo="$1" patch="$2"
  git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1
}

patches_applied() {
  local repo="$1" patch_dir="$2"
  [ -d "$patch_dir" ] || return 0
  local patch
  for patch in "$patch_dir"/*.patch; do
    [ -e "$patch" ] || continue
    patch_reverse_check "$repo" "$patch" || return 1
  done
  return 0
}

checkout_pinned() {
  local repo="$1" commit="$2"
  if ! git -C "$repo" rev-parse --verify --quiet "$commit^{commit}" >/dev/null; then
    # 浅 clone 通常不包含目标 commit；GitHub/Gitee 都支持按 SHA 取单个提交。
    if ! git -C "$repo" fetch --depth 1 origin "$commit" >/dev/null 2>&1; then
      git -C "$repo" fetch origin >/dev/null 2>&1
    fi
  fi
  git -C "$repo" checkout --detach "$commit" >/dev/null 2>&1
  local head
  head="$(git -C "$repo" rev-parse HEAD)"
  if [ "$head" != "$commit" ]; then
    echo "错误：$repo 无法切换到固定提交 $commit（当前 $head）" >&2
    return 1
  fi
}

ensure_repo() {
  local name="$1" url="$2" ref="$3" commit="$4" dest="$5" patch_dir="${6:-}" patched_commit="${7:-}"

  if [ -e "$dest/.git" ]; then
    local head
    head="$(git -C "$dest" rev-parse HEAD)"
    if [ "$head" = "$commit" ]; then
      if [ -n "$patch_dir" ] && patches_applied "$dest" "$patch_dir"; then
        echo "==== ${name}：源码已就绪（patches 已应用） ===="
      else
        echo "==== ${name}：源码版本正确 ===="
      fi
      return 0
    fi
    # 允许工作区停留在“基础版本 + 已应用 patch”对应的本地提交上。
    if [ -n "$patched_commit" ] && [ "$head" = "$patched_commit" ] \
      && [ -n "$patch_dir" ] && patches_applied "$dest" "$patch_dir"; then
      echo "==== ${name}：源码已就绪（patches 已应用） ===="
      return 0
    fi
    echo "错误：$name 已存在但不是固定版本。" >&2
    echo "  路径: $dest" >&2
    echo "  当前: $head" >&2
    echo "  期望: $commit" >&2
    echo "请先手动清理该目录或切回固定版本后重试。" >&2
    return 1
  fi

  if [ -e "$dest" ]; then
    if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
      echo "错误：$dest 已存在且不是 git 仓库，请手动清理后重试。" >&2
      return 1
    fi
    rmdir "$dest"
  fi

  mkdir -p "$(dirname "$dest")"
  echo "==== ${name}：clone $url ($ref) ===="
  if ! git clone --depth 1 --branch "$ref" "$url" "$dest" >/dev/null 2>&1; then
    git clone --no-checkout "$url" "$dest"
  fi
  checkout_pinned "$dest" "$commit"
}

apply_patches() {
  local repo="$1" patch_dir="$2" name="$3"
  [ -d "$patch_dir" ] || return 0
  local patch
  for patch in "$patch_dir"/*.patch; do
    [ -e "$patch" ] || continue
    if git -C "$repo" apply --check "$patch" >/dev/null 2>&1; then
      echo "==== ${name}：应用 $(basename "$patch") ===="
      git -C "$repo" apply "$patch"
    elif patch_reverse_check "$repo" "$patch"; then
      echo "==== ${name}：$(basename "$patch") 已应用 ===="
    else
      echo "错误：$name 无法应用 patch：$patch" >&2
      return 1
    fi
  done
}

ensure_repo \
  "FFmpeg" "$FFMPEG_URL" "$FFMPEG_REF" "$FFMPEG_COMMIT" \
  "$VENDOR/ffmpeg/ffmpeg-src" "$VENDOR/ffmpeg/patches"
apply_patches "$VENDOR/ffmpeg/ffmpeg-src" "$VENDOR/ffmpeg/patches" "FFmpeg"

ensure_repo \
  "AMSMB2" "$AMSMB2_URL" "$AMSMB2_REF" "$AMSMB2_COMMIT" \
  "$VENDOR/AMSMB2" "$VENDOR/AMSMB2-patches" "840ba89da068431d82ccfe2fdc71ab07a775cdbe"
apply_patches "$VENDOR/AMSMB2" "$VENDOR/AMSMB2-patches" "AMSMB2"

ensure_repo \
  "libsmb2" "$LIBSMB2_URL" "master" "$LIBSMB2_COMMIT" \
  "$VENDOR/AMSMB2/Dependencies/libsmb2"

echo
echo "==== 三方源码准备完成 ===="
echo "FFmpeg:  $(git -C "$VENDOR/ffmpeg/ffmpeg-src" rev-parse --short HEAD) + patches"
echo "AMSMB2:  $(git -C "$VENDOR/AMSMB2" rev-parse --short HEAD) + patches"
echo "libsmb2: $(git -C "$VENDOR/AMSMB2/Dependencies/libsmb2" rev-parse --short HEAD)"
echo
echo "下一步："
echo "  cd Vendor/ffmpeg && ./build.sh    # 重新生成 FFmpeg 静态库"
echo "  xcodegen generate                 # 工程文件变动后"

#!/bin/bash
# 为 iOS 构建最小化 FFmpeg 静态库（arm64 真机 + arm64 模拟器）。
# 只启用播放所需组件：解封装、音视频解码、swscale、swresample。
# 两种架构分别在独立的构建目录中进行，避免对象文件互相污染。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/ffmpeg-src"
JOBS="$(sysctl -n hw.ncpu)"

COMMON_CONFIG=(
  --disable-programs
  --disable-doc
  --disable-network
  --disable-autodetect
  --disable-encoders
  --disable-muxers
  --disable-filters
  --disable-devices
  --disable-avdevice
  --disable-postproc
  --disable-everything
  --enable-avformat
  --enable-avcodec
  --enable-avutil
  --enable-swscale
  --enable-swresample
  --enable-static
  --disable-shared
  --enable-pic
  --enable-protocol=file
  --enable-demuxer=matroska,mov,mp4,m4v,avi,mpegts
  --enable-decoder=h264,hevc,aac,opus,flac,ac3,eac3,dca,vorbis,ass,ssa,subrip,webvtt
  --enable-parser=h264,hevc,aac,opus,flac,ac3,vorbis
  --disable-stripping
)

build_arch() {
  local name="$1" target="$2" sdk="$3"
  local prefix="$ROOT/build/$name"
  local workdir="$ROOT/build/$name-work"
  local sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  echo "==== 构建 $name (target=$target) ===="
  rm -rf "$prefix" "$workdir"
  mkdir -p "$prefix" "$workdir"

  cd "$workdir"
  "$SRC/configure" \
    --prefix="$prefix" \
    --enable-cross-compile \
    --target-os=darwin \
    --arch=arm64 \
    --cc="$(xcrun -sdk "$sdk" -f clang)" \
    --extra-cflags="-target $target -isysroot $sysroot -O3" \
    --extra-ldflags="-target $target -isysroot $sysroot" \
    "${COMMON_CONFIG[@]}" \
    > "$prefix/configure.log" 2>&1

  make -j"$JOBS" > "$prefix/make.log" 2>&1
  make install > "$prefix/install.log" 2>&1
  echo "==== $name 完成 ===="
  cd "$ROOT"
}

mkdir -p "$ROOT/build"
build_arch "device" "arm64-apple-ios26.0" "iphoneos"
build_arch "simulator" "arm64-apple-ios26.0-simulator" "iphonesimulator"

LIBS="libavformat libavcodec libavutil libswscale libswresample"
rm -rf "$ROOT/lib" "$ROOT/include"
mkdir -p "$ROOT/lib/iphoneos" "$ROOT/lib/iphonesimulator" "$ROOT/include"
cp -R "$ROOT/build/device/include/"* "$ROOT/include/"
for lib in $LIBS; do
  cp "$ROOT/build/device/lib/$lib.a" "$ROOT/lib/iphoneos/"
  cp "$ROOT/build/simulator/lib/$lib.a" "$ROOT/lib/iphonesimulator/"
done

echo "==== 全部完成 ===="
ls -lh "$ROOT/lib/iphoneos" "$ROOT/lib/iphonesimulator"

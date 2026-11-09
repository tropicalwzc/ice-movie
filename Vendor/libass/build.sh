#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/out"
mkdir -p "$SRC" "$OUT"
cd "$SRC"

fetch() { [ -f "$2" ] || curl -sL --retry 4 --retry-delay 3 --max-time 600 -o "$2" "$1"; }
fetch https://github.com/libass/libass/releases/download/0.17.1/libass-0.17.1.tar.xz libass.tar.xz
fetch https://github.com/fribidi/fribidi/releases/download/v1.0.15/fribidi-1.0.15.tar.xz fribidi.tar.xz
# freetype 的 GitHub Release 没有附带源码包，使用 GNU Savannah 镜像。
fetch https://download.savannah.gnu.org/releases/freetype/freetype-2.13.2.tar.xz freetype.tar.xz
# libass 0.17 起 HarfBuzz 为必需依赖。
fetch https://github.com/harfbuzz/harfbuzz/releases/download/6.0.0/harfbuzz-6.0.0.tar.xz harfbuzz.tar.xz

# macOS 自带 libtoolize 缺失时，Homebrew 提供的是 glibtoolize。
if [ -z "${LIBTOOLIZE:-}" ]; then
  if command -v glibtoolize >/dev/null 2>&1; then
    export LIBTOOLIZE="$(command -v glibtoolize)"
  fi
fi

for n in libass-0.17.1 fribidi-1.0.15 freetype-2.13.2; do
  [ -d "$n" ] || tar xf "${n%%-*}.tar.xz" 2>/dev/null || true
done
[ -d libass-0.17.1 ] || tar xf libass.tar.xz
[ -d fribidi-1.0.15 ] || tar xf fribidi.tar.xz
[ -d freetype-2.13.2 ] || tar xf freetype.tar.xz
[ -d harfbuzz-6.0.0 ] || tar xf harfbuzz.tar.xz

build_platform() {
  local name="$1" target="$2" sdk="$3"
  local prefix="$OUT/$name"
  local sysroot cc cflags ldflags
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun -sdk "$sdk" -f clang)"
  cflags="-target $target -isysroot $sysroot -O2 -fPIC"
  ldflags="-target $target -isysroot $sysroot"
  rm -rf "$prefix"; mkdir -p "$prefix"

  echo "==== freetype ($name) ===="
  rm -rf "work-ft-$name"; mkdir "work-ft-$name"; cd "work-ft-$name"
  "$SRC/freetype-2.13.2/configure" --host=arm-apple-darwin --prefix="$prefix" \
    --disable-shared --enable-static --without-harfbuzz --without-png --without-brotli --without-zlib --without-bzip2 \
    CC="$cc" CFLAGS="$cflags" LDFLAGS="$ldflags" > ft.log 2>&1
  make -j8 >> ft.log 2>&1 && make install >> ft.log 2>&1
  cd "$SRC"

  echo "==== fribidi ($name) ===="
  rm -rf "work-fb-$name"; mkdir "work-fb-$name"; cd "work-fb-$name"
  "$SRC/fribidi-1.0.15/configure" --host=arm-apple-darwin --prefix="$prefix" \
    --disable-shared --enable-static --disable-docs --disable-debug \
    CC="$cc" CFLAGS="$cflags" LDFLAGS="$ldflags" > fb.log 2>&1
  make -j8 >> fb.log 2>&1 && make install >> fb.log 2>&1
  cd "$SRC"

  echo "==== harfbuzz ($name) ===="
  rm -rf "work-hb-$name"; mkdir "work-hb-$name"; cd "work-hb-$name"
  ../harfbuzz-6.0.0/configure --host=arm-apple-darwin --prefix="$prefix" \
    --disable-shared --enable-static \
    --with-glib=no --with-gobject=no --with-cairo=no --with-icu=no \
    --with-graphite2=no --with-freetype=no --with-coretext=no \
    CC="$cc" CFLAGS="$cflags" CXX="$cc" CXXFLAGS="$cflags" LDFLAGS="$ldflags" > hb.log 2>&1
  # autotools 的 util/test 子目录会尝试链接宿主机二进制，这里只构建并安装库本身。
  make -C src -j8 libharfbuzz.la libharfbuzz-subset.la harfbuzz.pc harfbuzz-subset.pc >> hb.log 2>&1
  mkdir -p "$prefix/lib" "$prefix/include/harfbuzz" "$prefix/lib/pkgconfig"
  cp src/.libs/libharfbuzz.a src/.libs/libharfbuzz-subset.a "$prefix/lib/"
  cp ../harfbuzz-6.0.0/src/*.h "$prefix/include/harfbuzz/"
  cp src/hb-version.h "$prefix/include/harfbuzz/" 2>/dev/null || true
  cp src/harfbuzz.pc src/harfbuzz-subset.pc "$prefix/lib/pkgconfig/"
  cd "$SRC"

  echo "==== libass ($name) ===="
  rm -rf "work-la-$name"; mkdir "work-la-$name"; cd "work-la-$name"
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
  export PKG_CONFIG="$(command -v pkg-config)"
  "$SRC/libass-0.17.1/configure" --host=arm-apple-darwin --prefix="$prefix" \
    --disable-shared --enable-static --disable-fontconfig --disable-require-system-font-provider \
    CC="$cc" CFLAGS="$cflags" LDFLAGS="$ldflags -L$prefix/lib" > la.log 2>&1
  make -j8 >> la.log 2>&1 && make install >> la.log 2>&1
  cd "$SRC"
}

build_platform iphoneos arm64-apple-ios26.0 iphoneos
build_platform iphonesimulator arm64-apple-ios26.0-simulator iphonesimulator
echo "==== 完成 ===="

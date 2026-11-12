#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
FIXTURES="IceMovieTests/Fixtures/ImageGallery"
ICON="IceMovie/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
BASE="/tmp/icemovie-base.png"

mkdir -p "$FIXTURES"

sips -z 64 64 "$ICON" --out "$BASE" >/dev/null
sips -s format jpeg "$BASE" --out "$FIXTURES/sample.jpg" >/dev/null
sips -s format heic "$BASE" --out "$FIXTURES/sample.heic" >/dev/null
cp "$FIXTURES/sample.heic" "$FIXTURES/sample.heif"

swift Scripts/make-image-fixtures.swift

if [[ -n "${MOV_SOURCE:-}" ]]; then
  avconvert \
    --source "$MOV_SOURCE" \
    --preset Preset640x480 \
    --output "$FIXTURES/motion.mov" \
    --duration 0.4 \
    --replace
fi

if [[ ! -f "$FIXTURES/motion.mov" ]]; then
  echo "缺少 $FIXTURES/motion.mov；请传入 MOV_SOURCE=<本地影片> 生成 0.4 秒样本。" >&2
  exit 1
fi

rm -f \
  "$FIXTURES/sample-stored.livp" \
  "$FIXTURES/sample-deflated.livp" \
  "$FIXTURES/sample-no-motion.livp" \
  "$FIXTURES/sample-no-still.livp"

(
  cd "$FIXTURES"
  zip -0 -j sample-stored.livp sample.heic motion.mov >/dev/null
  zip -9 -j sample-deflated.livp sample.heic motion.mov >/dev/null
  zip -0 -j sample-no-motion.livp sample.heic >/dev/null
  zip -0 -j sample-no-still.livp motion.mov >/dev/null
)

dd if=/dev/urandom of="$FIXTURES/broken.livp" bs=1024 count=2 2>/dev/null

echo "image fixtures ready in $FIXTURES"

#!/bin/zsh
# Rotate the random playback/seek stress test across several SMB shares (disks).
#
# Usage:
#   DEVICE_ID=... ./Scripts/run-multi-share-benchmark.sh
#
# Optional:
#   SHARES="sevenshare FiveShare nineshare sensei Videos"
#   COUNT=16 PLAY_SECONDS=60 SEEK_AFTER=4 SEEK_FRACTION=0.5 TIME_LIMIT=1800
#   ROOT_FOLDERS=12 PER_DIR=4
#   OUT_DIR=docs
set -u

: "${DEVICE_ID:?Set DEVICE_ID to the devicectl device identifier}"
BUNDLE_ID=${BUNDLE_ID:-com.wangzicheng.icemovie}
SMB_HOST=${SMB_HOST:-tropical-bigpc.lan}
SHARES=${SHARES:-"sevenshare FiveShare nineshare sensei Videos"}
COUNT=${COUNT:-16}
PLAY_SECONDS=${PLAY_SECONDS:-60}
SEEK_AFTER=${SEEK_AFTER:-4}
SEEK_FRACTION=${SEEK_FRACTION:-0.5}
TIME_LIMIT=${TIME_LIMIT:-1800}
ROOT_FOLDERS=${ROOT_FOLDERS:-12}
PER_DIR=${PER_DIR:-4}
OUT_DIR=${OUT_DIR:-docs}
DATE_TAG=${DATE_TAG:-$(date +%Y-%m-%d)}
STAMP=${STAMP:-quick}

mkdir -p "$OUT_DIR"

for share in ${=SHARES}; do
  echo "=== [$share] start $(date '+%H:%M:%S') ==="
  out="$OUT_DIR/acceptance-${DATE_TAG}-${share}-${STAMP}.json"
  tmp="/private/tmp/ice-${share}-acceptance.json"
  rm -f "$tmp" "$out"

  xcrun devicectl device process launch \
    --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" -- \
    -smbHost "$SMB_HOST" -smbShare "$share" -library \
    -stressRandom \
    -stressRootFolders "$ROOT_FOLDERS" \
    -stressPerDirectoryLimit "$PER_DIR" \
    -stressCount "$COUNT" \
    -stressPlaySeconds "$PLAY_SECONDS" \
    -stressSeekAfter "$SEEK_AFTER" \
    -stressSeekFraction "$SEEK_FRACTION" \
    -stressTimeLimit "$TIME_LIMIT" \
    -stressHDFirst \
    -stressTolerateBufferStalls \
    -stressTolerateFileErrors \
    -resetPlaybackProgress \
    -resetAcceptanceReport \
    -acceptanceReport \
    -debugLog >/dev/null 2>&1

  sleep 10
  if ! xcrun devicectl device info processes --device "$DEVICE_ID" 2>/dev/null \
       | grep -q 'IceMovie.app/IceMovie'; then
    echo "=== [$share] app not running after launch ==="
  fi
  reason="timeout"
  max_loops=$(( (TIME_LIMIT + 600) / 30 + 4 ))
  for ((i = 1; i <= max_loops; i++)); do
    sleep 30
    rm -f "$tmp"
    xcrun devicectl device copy from --device "$DEVICE_ID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source Documents/ice-acceptance.json --destination "$tmp" >/dev/null 2>&1
    if [[ -f "$tmp" ]]; then
      if grep -q '"stressSeriousBug" : true' "$tmp"; then
        reason="serious-bug"
        break
      fi
      if grep -q '"stressDone" : true' "$tmp"; then
        reason="done"
        break
      fi
    fi
    if ! xcrun devicectl device info processes --device "$DEVICE_ID" 2>/dev/null \
         | grep -q 'IceMovie.app/IceMovie'; then
      reason="app-exited"
      break
    fi
  done

  rm -f "$tmp"
  xcrun devicectl device copy from --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/ice-acceptance.json --destination "$tmp" >/dev/null 2>&1
  if [[ -f "$tmp" ]]; then
    cp "$tmp" "$out"
  fi
  echo "=== [$share] stop reason=$reason file=$out $(date '+%H:%M:%S') ==="
  python3 - "$out" "$share" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print(f"  ! cannot read {sys.argv[1]}: {exc}")
    raise SystemExit
stress = [x for x in data if x.get("reason") == "stress"]
summary = next((x for x in data if x.get("stressDone")), {})
plan = next((x for x in reversed(data) if x.get("reason") == "stress-plan"), {})
print(f"  {sys.argv[2]}: played={len(stress)} candidates={plan.get('stressAllCount')} "
      f"picked={plan.get('stressPickCount')} stop={summary.get('stressStopReason')} "
      f"serious={summary.get('stressSeriousFound')} "
      f"fileExceptions={sum(1 for x in stress if x.get('stressFileException'))} "
      f"bufferExceptions={sum(1 for x in stress if x.get('stressBufferException'))}")
PY
done

echo "=== all shares finished $(date '+%H:%M:%S') ==="

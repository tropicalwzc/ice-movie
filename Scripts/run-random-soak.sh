#!/bin/zsh
# 随机时长 / 随机 seek 的长跑压力测试。
#
# 与 run-multi-share-benchmark.sh 的区别：
# - 每条播放时长在 PLAY_MIN...PLAY_MAX 秒之间随机；
# - 每条在 SEEK_AFTER_MIN...SEEK_AFTER_MAX 秒后 seek；
# - seek 落点在 SEEK_FRACTION_MIN...SEEK_FRACTION_MAX 之间随机；
# - 每个共享每轮跑 PER_SHARE_SECONDS；CYCLES>1 时按 共享列表循环多轮，
#   例如 5 个共享 × 12 分钟 × 4 轮 = 4 小时，且每个磁盘中间有 48 分钟休息。
#
# 必填：
#   DEVICE_ID=<devicectl 设备 ID>
# 可选：
#   SMB_HOST=tropical-bigpc.lan
#   SHARES="sevenshare FiveShare nineshare sensei Videos"
#   CYCLES=1
#   PER_SHARE_SECONDS=2880
#   PLAY_MIN=45 PLAY_MAX=150
#   SEEK_AFTER_MIN=3 SEEK_AFTER_MAX=12
#   SEEK_FRACTION_MIN=0.10 SEEK_FRACTION_MAX=0.85
#   COUNT=400 ROOT_FOLDERS=24 PER_DIR=40
#   OUT_DIR=docs DATE_TAG=$(date +%Y-%m-%d) STAMP=random-4h
set -u

: "${DEVICE_ID:?Set DEVICE_ID to the devicectl device identifier}"
BUNDLE_ID=${BUNDLE_ID:-com.wangzicheng.icemovie}
SMB_HOST=${SMB_HOST:-tropical-bigpc.lan}
SHARES=${SHARES:-"sevenshare FiveShare nineshare sensei Videos"}
CYCLES=${CYCLES:-1}
PER_SHARE_SECONDS=${PER_SHARE_SECONDS:-2880}
PLAY_MIN=${PLAY_MIN:-45}
PLAY_MAX=${PLAY_MAX:-150}
SEEK_AFTER_MIN=${SEEK_AFTER_MIN:-3}
SEEK_AFTER_MAX=${SEEK_AFTER_MAX:-12}
SEEK_FRACTION_MIN=${SEEK_FRACTION_MIN:-0.10}
SEEK_FRACTION_MAX=${SEEK_FRACTION_MAX:-0.85}
COUNT=${COUNT:-400}
ROOT_FOLDERS=${ROOT_FOLDERS:-24}
PER_DIR=${PER_DIR:-40}
OUT_DIR=${OUT_DIR:-docs}
DATE_TAG=${DATE_TAG:-$(date +%Y-%m-%d)}
STAMP=${STAMP:-random-4h}

mkdir -p "$OUT_DIR"

app_is_running() {
  xcrun devicectl device info processes --device "$DEVICE_ID" 2>/dev/null \
    | grep -q 'IceMovie.app/IceMovie'
}

for ((cycle = 1; cycle <= CYCLES; cycle++)); do
for share in ${=SHARES}; do
  cycle_tag=""
  if (( CYCLES > 1 )); then
    cycle_tag="-c${cycle}"
  fi
  out="$OUT_DIR/acceptance-${DATE_TAG}-${share}-${STAMP}${cycle_tag}.json"
  tmp="/private/tmp/ice-${share}-${STAMP}${cycle_tag}.json"
  rm -f "$tmp" "$out"

  echo "=== [$share] cycle=$cycle/$CYCLES start $(date '+%H:%M:%S') ==="
  xcrun devicectl device process launch \
    --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" -- \
    -smbHost "$SMB_HOST" -smbShare "$share" -library \
    -stressRandom -stressRandomize \
    -stressPlaySecondsMin "$PLAY_MIN" -stressPlaySecondsMax "$PLAY_MAX" \
    -stressSeekAfterMin "$SEEK_AFTER_MIN" -stressSeekAfterMax "$SEEK_AFTER_MAX" \
    -stressSeekFractionMin "$SEEK_FRACTION_MIN" -stressSeekFractionMax "$SEEK_FRACTION_MAX" \
    -stressCount "$COUNT" \
    -stressRootFolders "$ROOT_FOLDERS" \
    -stressPerDirectoryLimit "$PER_DIR" \
    -stressTimeLimit "$PER_SHARE_SECONDS" \
    -stressHDFirst \
    -stressTolerateBufferStalls \
    -stressTolerateFileErrors \
    -resetPlaybackProgress \
    -resetAcceptanceReport \
    -acceptanceReport \
    -debugLog >/dev/null 2>&1

  sleep 10
  reason="timeout"
  max_loops=$(( PER_SHARE_SECONDS / 60 + 20 ))
  for ((i = 1; i <= max_loops; i++)); do
    sleep 60
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
    if ! app_is_running; then
      sleep 5
      if ! app_is_running; then
        reason="app-exited"
        break
      fi
    fi
  done

  rm -f "$tmp"
  xcrun devicectl device copy from --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/ice-acceptance.json --destination "$tmp" >/dev/null 2>&1
  if [[ -f "$tmp" ]]; then
    cp "$tmp" "$out"
  fi
  echo "=== [$share] cycle=$cycle/$CYCLES stop reason=$reason file=$out $(date '+%H:%M:%S') ==="
  python3 - "$out" "$share" "$cycle" "$CYCLES" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print(f"  ! cannot read {sys.argv[1]}: {exc}")
    raise SystemExit
stress = [x for x in data if x.get("reason") == "stress"]
summary = next((x for x in data if x.get("stressDone")), {})
plan = next((x for x in reversed(data) if x.get("reason") == "stress-plan"), {})
print(f"  {sys.argv[2]} c{sys.argv[3]}/{sys.argv[4]}: played={len(stress)} "
      f"candidates={plan.get('stressAllCount')} "
      f"picked={plan.get('stressPickCount')} stop={summary.get('stressStopReason')} "
      f"serious={summary.get('stressSeriousFound')} "
      f"fileExceptions={sum(1 for x in stress if x.get('stressFileException'))} "
      f"bufferExceptions={sum(1 for x in stress if x.get('stressBufferException'))}")
PY
  sleep 20
done
done

echo "=== all cycles finished $(date '+%H:%M:%S') ==="

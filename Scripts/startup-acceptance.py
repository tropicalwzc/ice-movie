#!/usr/bin/env python3
"""Summarize startup latency fields from ice-acceptance.json.

Usage:
    python3 Scripts/startup-acceptance.py Documents/ice-acceptance.json
"""
import json
import statistics as stats
import sys

FIELDS = [
    "playerPresentedMilliseconds",
    "prepareMilliseconds",
    "openInputMilliseconds",
    "streamInfoMilliseconds",
    "firstVideoMilliseconds",
    "openBytesRead",
    "openReadCount",
    "avioFillCount",
    "attachmentBytes",
    "attachmentFontBytes",
    "skippedFontCount",
    "headerCacheHitBytes",
    "headerCacheHitRatio",
    "subtitleScanMilliseconds",
    "startupBufferStalls",
]


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return 0
    index = min(len(ordered) - 1, int(len(ordered) * fraction))
    return ordered[index]


def main(path):
    with open(path, encoding="utf-8") as handle:
        items = json.load(handle)
    rows = [
        row for row in items
        if row.get("reason") in {"closed", "stress", "replaced"}
        and "prepareMilliseconds" in row
    ]
    if not rows:
        print("没有可统计的播放记录")
        return 1

    print(f"样本数: {len(rows)}")
    for field in FIELDS:
        values = [row[field] for row in rows if isinstance(row.get(field), (int, float))]
        if not values:
            continue
        print(
            f"{field:30} min={min(values):>10.2f} "
            f"p50={percentile(values, 0.5):>10.2f} "
            f"p90={percentile(values, 0.9):>10.2f} "
            f"max={max(values):>10.2f} "
            f"mean={stats.mean(values):>10.2f}"
        )

    first_frame = [
        row.get("prepareMilliseconds", 0) + row.get("firstVideoMilliseconds", 0)
        for row in rows
    ]
    within = sum(1 for value in first_frame if value <= 1500)
    print(
        f"点击→首帧 <=1.5s: {within}/{len(rows)} "
        f"({within / len(rows) * 100:.1f}%)"
    )
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))

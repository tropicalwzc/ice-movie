#!/usr/bin/env python3
"""Turn IceMovie ice-acceptance.json into a Markdown playback benchmark report.

Usage:
  python3 Scripts/playback-benchmark-report.py \
    --input ipad-seven-soak.json --output docs/acceptance-...-sevenshare-2h.md \
    --title "sevenshare 2 小时随机起播验收" \
    --device "iPad Air 11-inch (M2), iOS 27.0.1" \
    --host "TROPICAL-BIGPC.local" --share "sevenshare" --storage "SATA SSD"
"""
import argparse
import json
import re
import statistics
from pathlib import Path


def val(item, key, default=0):
    v = item.get(key, default)
    return default if v is None else v


def ms(v):
    try:
        return f"{int(float(v))}ms"
    except Exception:
        return "—"


def sec(v):
    try:
        return f"{float(v):.3f}s"
    except Exception:
        return "—"


def num(v):
    try:
        return float(v)
    except Exception:
        return 0.0


def q(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return 0
    return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]


def line(name, values, fmt):
    if not values:
        return f"- {name}：—"
    return (
        f"- {name}：最小 {fmt(min(values))} / p50 {fmt(q(values, 0.5))} "
        f"/ p90 {fmt(q(values, 0.9))} / 最大 {fmt(max(values))} "
        f"/ 平均 {fmt(statistics.mean(values))}"
    )


def short(path, n=46):
    s = path or ""
    return s if len(s) <= n else "…" + s[-(n - 1):]


def arg_number(text, key, default):
    match = re.search(rf"{re.escape(key)}\s+(-?\d+(?:\.\d+)?)", text or "")
    return float(match.group(1)) if match else float(default)


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join(["---"] * len(headers)) + "|"]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--title", default="播放性能报告")
    ap.add_argument("--device", default="iPad 真机")
    ap.add_argument("--host", default="—")
    ap.add_argument("--share", default="—")
    ap.add_argument("--storage", default="—")
    ap.add_argument("--args", default="")
    args = ap.parse_args()

    data = json.load(open(args.input))
    stress = [x for x in data if x.get("reason") == "stress"]
    open_failed = [x for x in data if x.get("reason") == "stress-open-failed"]
    summary = next((x for x in data if x.get("stressDone")), {})
    plans = [x for x in data if x.get("reason") == "stress-plan"]
    plan = plans[-1] if plans else {}
    if not summary:
        summary = {
            "capturedAt": stress[-1].get("capturedAt", "—") if stress else "—",
            "stressStopReason": "segmented/no-summary",
        }

    click_first = [num(val(x, "clickToFirstVideoMilliseconds")) for x in stress
                   if val(x, "clickToFirstVideoMilliseconds")]
    presented = [num(val(x, "playerPresentedMilliseconds")) for x in stress
                 if num(val(x, "playerPresentedMilliseconds")) > 0]
    prepare = [num(val(x, "prepareMilliseconds")) for x in stress]
    open_input = [num(val(x, "openInputMilliseconds")) for x in stress]
    probe = [num(val(x, "streamInfoMilliseconds")) for x in stress]
    first_frame = [num(val(x, "firstVideoMilliseconds")) for x in stress]
    open_bytes = [num(val(x, "openBytesRead")) for x in stress]
    cache_ratio = [num(val(x, "headerCacheHitRatio")) for x in stress]
    seek_latency = [num(val(x, "lastSeekLatencyMilliseconds")) for x in stress
                    if val(x, "lastSeekLatencyMilliseconds")]
    seek_drift = [abs(num(val(x, "lastSeekDrift"))) for x in stress]
    seek_tb = [num(val(x, "maxSeekTimebaseOffset")) for x in stress]
    seek_tb_jumps = [int(num(val(x, "seekTimebaseJumpCount"))) for x in stress]
    post_stalls = [int(num(val(x, "postSeekBufferStalls"))) for x in stress]
    post_seconds = [num(val(x, "postSeekBufferSeconds")) for x in stress]
    total_stalls = [int(num(val(x, "bufferStalls"))) for x in stress]
    total_seconds = [num(val(x, "bufferSeconds")) for x in stress]
    startup_stalls = [int(num(val(x, "startupBufferStalls"))) for x in stress]
    max_drift = [num(val(x, "maxDrift")) for x in stress]
    clock_jumps = [int(num(val(x, "clockJumpCount"))) for x in stress]
    subtitle_cues = [int(num(val(x, "subtitleCues"))) for x in stress]
    subtitle_first = [num(val(x, "subtitleFirstCueMilliseconds")) for x in stress
                      if int(num(val(x, "subtitleCues"))) > 0
                      and num(val(x, "subtitleFirstCueMilliseconds")) > 0]
    skipped_fonts = [int(num(val(x, "skippedFontCount"))) for x in stress]
    subtitle_errors = [x for x in stress if (x.get("subtitleError") or "").strip()]
    file_exceptions = [x for x in stress if x.get("stressFileException") is True]
    buffer_exceptions = sum(1 for x in stress if x.get("stressBufferException") is True)
    serious = sum(1 for x in stress if x.get("stressSeriousBug") is True)
    sync_ok = sum(1 for x in stress if x.get("stressSyncOK") is True)

    under_1500 = sum(1 for v in click_first if v <= 1500)
    mode_fast = sum(1 for x in stress if x.get("startupPrerollMode") == "fast")
    mode_cons = sum(1 for x in stress if x.get("startupPrerollMode") == "conservative")
    has_timebase = any("maxSeekTimebaseOffset" in x for x in stress)

    violations = []
    for x in stress:
        idx = x.get("stressIndex")
        path = short(x.get("path"), 42)
        cf = num(val(x, "clickToFirstVideoMilliseconds"))
        if cf > 5000:
            violations.append((idx, path, "首帧 >5s", ms(cf)))
        elif cf > 1500:
            violations.append((idx, path, "首帧 >1.5s", ms(cf)))
        cue = num(val(x, "subtitleFirstCueMilliseconds"))
        if int(num(val(x, "subtitleCues"))) > 0 and cue > 5000:
            violations.append((idx, path, "字幕首条 >5s", ms(cue)))
        elif int(num(val(x, "subtitleCues"))) > 0 and cue > 3000:
            violations.append((idx, path, "字幕首条 >3s", ms(cue)))
        ps = num(val(x, "postSeekBufferSeconds"))
        if ps > 10:
            violations.append((idx, path, "seek 后缓冲 >10s", sec(ps)))
        elif ps > 3:
            violations.append((idx, path, "seek 后缓冲 >3s", sec(ps)))
        if int(num(val(x, "clockJumpCount"))) > 0:
            violations.append((idx, path, "clockJumpCount >0", int(num(val(x, "clockJumpCount")))))
        if num(val(x, "maxDrift")) >= 0.5:
            violations.append((idx, path, "maxDrift ≥0.5s", sec(x.get("maxDrift"))))
        tb = num(val(x, "maxSeekTimebaseOffset"))
        if tb > 1.0:
            violations.append((idx, path, "seek 后时间基偏差 >1s", sec(tb)))
        if int(num(val(x, "seekTimebaseJumpCount"))) > 0:
            violations.append((idx, path, "seek 后画面时间基跳变", int(num(val(x, "seekTimebaseJumpCount")))))

    play_seconds = arg_number(args.args, "-stressPlaySeconds", 85)
    seek_after = arg_number(args.args, "-stressSeekAfter", 60)
    seek_fraction = arg_number(args.args, "-stressSeekFraction", 0.6667)
    tail_seconds = max(0, play_seconds - seek_after)

    lines = [
        f"# {args.title}",
        "",
        f"- 日期：{summary.get('capturedAt', '—')}",
        f"- 设备：{args.device}",
        f"- 主机：`{args.host}` / 共享：`{args.share}`",
        f"- 存储：{args.storage}",
        f"- 测试方式：随机打开视频；每条播放 {play_seconds:g} 秒"
        f"（第 {seek_after:g} 秒 seek 到 {seek_fraction * 100:.2f}%），"
        f"再播放 {tail_seconds:g} 秒",
        f"- 候选样本：{plan.get('stressAllCount', '—')}，计划抽取：{plan.get('stressPickCount', '—')}",
        f"- 启动参数：`{args.args}`" if args.args else "",
        "",
        "## 总体结果",
        "",
        f"- 完成视频：**{len(stress)}** 条",
        f"- 硬件严重问题：{serious}",
        f"- 文件/内容异常（已记录）：{len(file_exceptions)}",
        f"- 打开失败（历史路径失效）：{len(open_failed)}",
        f"- 环境缓冲异常（已记录）：{buffer_exceptions}",
        f"- 音画同步异常：{len(stress) - sync_ok}（通过 {sync_ok}/{len(stress)}）",
        f"- 点击→首帧 ≤1.5s：{under_1500}/{len(click_first)}",
        f"- 起播档位：fast {mode_fast} / conservative {mode_cons}",
        f"- 字幕错误：{len(subtitle_errors)} 条",
        f"- 总结：{summary.get('stressStopReason', '—')}；严重={summary.get('stressSeriousFound', '—')}；"
        f"环境缓冲={summary.get('stressBufferExceptions', '—')}；同步异常={summary.get('stressSyncIssues', '—')}",
        "",
        "## 启动耗时",
        "",
        line("播放页出现", presented, ms),
        line("点击 → 首帧", click_first, ms),
        line("准备（SMB + 探测 + 字幕 + 引擎）", prepare, ms),
        line("容器打开", open_input, ms),
        line("流信息探测", probe, ms),
        line("播放开始 → 首帧", first_frame, ms),
        line("打开阶段读取字节", open_bytes, lambda v: f"{int(v / 1024)}KB"),
        line("容器头缓存命中率", cache_ratio, lambda v: f"{v * 100:.1f}%"),
        "",
        "## 字幕",
        "",
        line("字幕条数", subtitle_cues, lambda v: f"{int(v)} 条"),
        line("开始加载 → 首条 cue", subtitle_first, ms),
        line("跳过字体附件", skipped_fonts, lambda v: f"{int(v)} 个"),
        f"- 字幕错误：{len(subtitle_errors)} 条",
        "",
        "## Seek 与缓冲",
        "",
        line("seek 延迟", seek_latency, ms),
        line("seek 后新增缓冲次数", post_stalls, lambda v: f"{int(v)} 次"),
        line("seek 后新增缓冲秒数", post_seconds, sec),
        line("每条总缓冲次数", total_stalls, lambda v: f"{int(v)} 次"),
        line("每条累计缓冲", total_seconds, sec),
        line("起播后 30s 缓冲次数", startup_stalls, lambda v: f"{int(v)} 次"),
        "",
        "## 音画同步",
        "",
        line("整体 maxDrift", max_drift, sec),
        line("seek 后 lastSeekDrift", seek_drift, sec),
        *(
            [
                line("seek 后显示层时间基偏差", seek_tb, sec),
                f"- seek 后时间基跳变（>1s）样本：{sum(1 for v in seek_tb_jumps if v > 0)}",
            ]
            if has_timebase
            else [
                "- seek 后显示层时间基偏差：未采集（旧报告）",
                "- seek 后时间基跳变：未采集（旧报告）",
            ]
        ),
        f"- clockJumpCount > 0 的样本：{sum(1 for v in clock_jumps if v > 0)}",
        "",
    ]

    if violations:
        lines += ["## 超标记录", ""] + table(
            ["#", "文件", "项", "值"], violations[:80]
        ) + [""]
    else:
        lines += ["## 超标记录", "", "无。", ""]

    if file_exceptions:
        lines += ["## 文件/内容异常", ""] + table(
            ["#", "文件", "原因", "恢复次数", "状态"],
            [[x.get("stressIndex"), short(x.get("path"), 40),
              x.get("stressReason", ""), int(num(val(x, "videoRecoveries"))),
              x.get("videoStatus", "")] for x in file_exceptions],
        ) + [""]

    if open_failed:
        lines += ["## 打开失败（历史路径失效）", ""] + table(
            ["#", "文件", "原因"],
            [[x.get("stressIndex"), short(x.get("path"), 52),
              x.get("failure", "")] for x in open_failed],
        ) + [""]

    lines += ["## 启动最慢的 10 条", ""] + table(
        ["#", "文件", "点击→首帧", "播放页", "准备", "打开", "探测", "首帧"],
        [[x.get("stressIndex"), short(x.get("path"), 34),
          ms(x.get("clickToFirstVideoMilliseconds")),
          ms(x.get("playerPresentedMilliseconds")),
          ms(x.get("prepareMilliseconds")), ms(x.get("openInputMilliseconds")),
          ms(x.get("streamInfoMilliseconds")), ms(x.get("firstVideoMilliseconds"))]
         for x in sorted(stress, key=lambda z: -num(val(z, "clickToFirstVideoMilliseconds")))[:10]],
    ) + [""]

    lines += ["## 字幕最慢的 10 条", ""] + table(
        ["#", "文件", "字幕首条 cue", "字幕条数", "轨道"],
        [[x.get("stressIndex"), short(x.get("path"), 36),
          ms(x.get("subtitleFirstCueMilliseconds")), int(num(val(x, "subtitleCues"))),
          x.get("subtitleTrack", "")]
         for x in sorted([x for x in stress if int(num(val(x, "subtitleCues"))) > 0],
                         key=lambda z: -num(val(z, "subtitleFirstCueMilliseconds")))[:10]],
    ) + [""]

    lines += ["## seek 后缓冲最重的 10 条", ""] + table(
        ["#", "文件", "seek", "命中", "seek 后缓冲", "seek 后缓冲秒", "总缓冲"],
        [[x.get("stressIndex"), short(x.get("path"), 34),
          ms(x.get("lastSeekLatencyMilliseconds")), "✓" if x.get("seekCacheHit") else "✗",
          f"{int(num(val(x, 'postSeekBufferStalls')))} 次",
          sec(x.get("postSeekBufferSeconds")),
          f"{int(num(val(x, 'bufferStalls')))} 次"]
         for x in sorted(stress, key=lambda z: -num(val(z, "postSeekBufferSeconds")))[:10]],
    ) + [""]

    lines += ["## 逐条明细", ""] + table(
        ["#", "文件", "启动", "播放页", "准备", "打开", "探测", "首帧",
         "同步", "maxDrift", "时间基", "seek", "命中", "seek后缓冲", "字幕首cue", "字幕"],
        [[x.get("stressIndex"), short(x.get("path"), 28),
          ms(x.get("clickToFirstVideoMilliseconds")),
          ms(x.get("playerPresentedMilliseconds")),
          ms(x.get("prepareMilliseconds")), ms(x.get("openInputMilliseconds")),
          ms(x.get("streamInfoMilliseconds")), ms(x.get("firstVideoMilliseconds")),
          "✓" if x.get("stressSyncOK") else "✗", sec(x.get("maxDrift")),
          "—" if "maxSeekTimebaseOffset" not in x else sec(x.get("maxSeekTimebaseOffset")),
          ms(x.get("lastSeekLatencyMilliseconds")),
          "✓" if x.get("seekCacheHit") else "✗",
          sec(x.get("postSeekBufferSeconds")),
          ms(x.get("subtitleFirstCueMilliseconds")),
          f"{int(num(val(x, 'subtitleCues')))} 条"]
         for x in stress],
    ) + [""]

    lines += ["## 结论", ""]
    if not stress:
        lines.append("没有可分析样本。")
    elif serious:
        lines.append("存在硬件/解码严重问题，测试提前停止；详见逐条明细。")
    else:
        lines.append(
            f"测试完成；无硬件严重问题；文件/内容异常 {len(file_exceptions)} 条、"
            f"环境缓冲异常 {buffer_exceptions} 条、超标记录 {len(violations)} 条。"
        )
    lines += ["", f"原始 JSON：`{Path(args.input).name}`"]

    Path(args.output).write_text("\n".join(line for line in lines if line is not None))
    print(
        f"wrote {args.output}: {len(stress)} entries, violations={len(violations)}, "
        f"file_exceptions={len(file_exceptions)}, serious={serious}"
    )


if __name__ == "__main__":
    main()

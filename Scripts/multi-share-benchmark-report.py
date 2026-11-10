#!/usr/bin/env python3
"""Build a multi-share playback benchmark report from several ice-acceptance.json files.

Usage:
  python3 Scripts/multi-share-benchmark-report.py \
    --input sevenshare=docs/acceptance-...-sevenshare-quick.json \
    --input FiveShare=docs/acceptance-...-FiveShare-quick.json \
    --output docs/acceptance-2026-11-10-multi-share-quick.md \
    --device "iPad Air 11-inch (M2)" --host TROPICAL-BIGPC.local \
    --args "-stressRandom ..."
"""
import argparse
import json
import statistics
from datetime import datetime
from pathlib import Path


def num(item, key, default=0.0):
    value = item.get(key, default)
    if value is None:
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def ms(value):
    try:
        return f"{int(float(value))}ms"
    except (TypeError, ValueError):
        return "—"


def sec(value):
    try:
        return f"{float(value):.3f}s"
    except (TypeError, ValueError):
        return "—"


def pct(value):
    try:
        return f"{float(value) * 100:.1f}%"
    except (TypeError, ValueError):
        return "—"


def q(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return 0
    return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]


def stat_line(name, values, fmt):
    if not values:
        return f"- {name}：—"
    return (
        f"- {name}：最小 {fmt(min(values))} / p50 {fmt(q(values, 0.5))} "
        f"/ p90 {fmt(q(values, 0.9))} / 最大 {fmt(max(values))} "
        f"/ 平均 {fmt(statistics.mean(values))}"
    )


def short(path, limit=44):
    text = path or ""
    return text if len(text) <= limit else "…" + text[-(limit - 1):]


def table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join(["---"] * len(headers)) + "|"]
    out += ["| " + " | ".join(str(cell) for cell in row) + " |" for row in rows]
    return out


def values(items, key):
    """提取数值。缺失、null、空串或非法值一律剔除，不能折算成 0.0：
    否则会虚增 ≤1.5s/≤2s/≤5s 达标数量、拉低首帧均值/p90，
    且让缺失样本占着分母（如旧报告中缺失首帧耗时的 14 条被算成
    14/14 达标）。分母只计有效样本，缺失数在报告中单独标注。"""
    out = []
    for item in items:
        raw = item.get(key)
        if raw is None or raw == "":
            continue
        try:
            out.append(float(raw))
        except (TypeError, ValueError):
            continue
    return out


def abs_values(items, key):
    return [abs(num(item, key)) for item in items]


def load_share(share, path):
    data = json.load(open(path))
    stress = [item for item in data if item.get("reason") == "stress"]
    open_failed = [item for item in data if item.get("reason") == "stress-open-failed"]
    plan = next((item for item in reversed(data) if item.get("reason") == "stress-plan"), {})
    summary = next((item for item in data if item.get("stressDone")), {})
    return {
        "share": share,
        "path": path,
        "stress": stress,
        "open_failed": open_failed,
        "plan": plan,
        "summary": summary,
    }


def summarize_share(entry):
    stress = entry["stress"]
    seek = [num(x, "lastSeekLatencyMilliseconds") for x in stress
            if num(x, "lastSeekLatencyMilliseconds") > 0]
    first = values(stress, "clickToFirstVideoMilliseconds")
    sync_ok = sum(1 for x in stress if x.get("stressSyncOK") is True)
    stamps = [x.get("capturedAt", "") for x in stress if x.get("capturedAt")]
    return {
        "share": entry["share"],
        "candidates": entry["plan"].get("stressAllCount", "—"),
        "picked": entry["plan"].get("stressPickCount", "—"),
        "played": len(stress),
        "sync_ok": sync_ok,
        "first_avg": statistics.mean(first) if first else 0,
        "first_p90": q(first, 0.9),
        "first_max": max(first) if first else 0,
        "seek_avg": statistics.mean(seek) if seek else 0,
        "seek_p90": q(seek, 0.9),
        "seek_max": max(seek) if seek else 0,
        "file_exceptions": sum(1 for x in stress if x.get("stressFileException") is True),
        "buffer_exceptions": sum(1 for x in stress if x.get("stressBufferException") is True),
        "open_failed": len(entry["open_failed"]),
        "stop": entry["summary"].get("stressStopReason", "—"),
        "serious": entry["summary"].get("stressSeriousFound", "—"),
        "started": min(stamps) if stamps else "—",
        "ended": max(stamps) if stamps else "—",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", action="append", required=True,
                        help="share=path/to/ice-acceptance.json")
    parser.add_argument("--output", required=True)
    parser.add_argument("--date", default=datetime.now().strftime("%Y-%m-%d"))
    parser.add_argument("--device", default="iPad 真机")
    parser.add_argument("--host", default="—")
    parser.add_argument("--build", default="Release")
    parser.add_argument("--args", default="")
    parser.add_argument("--play-seconds", type=float, default=60)
    parser.add_argument("--seek-after", type=float, default=4)
    parser.add_argument("--seek-fraction", type=float, default=0.5)
    parser.add_argument("--baseline", action="append", default=[],
                        help="label=path/to/older/ice-acceptance.json")
    args = parser.parse_args()

    entries = []
    for spec in args.input:
        share, _, path = spec.partition("=")
        if not path:
            share, path = Path(spec).stem, spec
        entry = load_share(share, path)
        for item in entry["stress"] + entry["open_failed"]:
            item["_share"] = share
        entries.append(entry)

    all_stress = [item for entry in entries for item in entry["stress"]]
    all_open_failed = [item for entry in entries for item in entry["open_failed"]]
    summaries = [summarize_share(entry) for entry in entries]

    click_first = [v for v in values(all_stress, "clickToFirstVideoMilliseconds") if v > 0]
    presented = [v for v in values(all_stress, "playerPresentedMilliseconds") if v > 0]
    prepare = values(all_stress, "prepareMilliseconds")
    open_input = values(all_stress, "openInputMilliseconds")
    probe = values(all_stress, "streamInfoMilliseconds")
    first_frame = values(all_stress, "firstVideoMilliseconds")
    open_bytes = values(all_stress, "openBytesRead")
    cache_ratio = values(all_stress, "headerCacheHitRatio")
    seek_latency = [v for v in values(all_stress, "lastSeekLatencyMilliseconds") if v > 0]
    max_drift = abs_values(all_stress, "maxDrift")
    last_seek_drift = abs_values(all_stress, "lastSeekDrift")
    seek_tb = values(all_stress, "maxSeekTimebaseOffset")
    last_seek_tb = values(all_stress, "lastSeekTimebaseOffset")
    seek_tb_jumps = [int(num(x, "seekTimebaseJumpCount")) for x in all_stress]
    clock_jumps = [int(num(x, "clockJumpCount")) for x in all_stress]
    post_stalls = [int(num(x, "postSeekBufferStalls")) for x in all_stress]
    post_seconds = values(all_stress, "postSeekBufferSeconds")
    total_stalls = [int(num(x, "bufferStalls")) for x in all_stress]
    total_seconds = values(all_stress, "bufferSeconds")
    startup_stalls = [int(num(x, "startupBufferStalls")) for x in all_stress]
    seek_cache_hits = sum(1 for x in all_stress if x.get("seekCacheHit") is True)

    valid_offsets = []
    offset_transients = 0
    for item in all_stress:
        offset = abs(num(item, "maxVideoOffset"))
        if offset > 10:
            offset_transients += 1
        else:
            valid_offsets.append(offset)

    sync_ok = sum(1 for x in all_stress if x.get("stressSyncOK") is True)
    file_exceptions = [x for x in all_stress if x.get("stressFileException") is True]
    buffer_exceptions = [x for x in all_stress if x.get("stressBufferException") is True]
    serious = sum(1 for x in all_stress if x.get("stressSeriousBug") is True)
    subtitle_errors = [x for x in all_stress if (x.get("subtitleError") or "").strip()]
    under_1500 = sum(1 for v in click_first if v <= 1500)
    under_2000 = sum(1 for v in click_first if v <= 2000)
    under_5000 = sum(1 for v in click_first if v <= 5000)
    click_first_missing = len(all_stress) - len(click_first)
    click_first_note = (
        f"（另有 {click_first_missing} 条缺失首帧耗时，未计入达标与统计）"
        if click_first_missing else ""
    )

    violations = []
    for item in all_stress:
        share = item.get("_share", "")
        label = short(item.get("path"), 38)
        cf = num(item, "clickToFirstVideoMilliseconds")
        if cf > 5000:
            violations.append((share, item.get("stressIndex"), label, "首帧 >5s", ms(cf)))
        elif cf > 1500:
            violations.append((share, item.get("stressIndex"), label, "首帧 >1.5s", ms(cf)))
        ps = num(item, "postSeekBufferSeconds")
        if ps > 10:
            violations.append((share, item.get("stressIndex"), label, "seek 后缓冲 >10s", sec(ps)))
        elif ps > 3:
            violations.append((share, item.get("stressIndex"), label, "seek 后缓冲 >3s", sec(ps)))
        if int(num(item, "clockJumpCount")) > 0:
            violations.append((share, item.get("stressIndex"), label, "clockJumpCount >0",
                               int(num(item, "clockJumpCount"))))
        if abs(num(item, "maxDrift")) >= 0.5:
            violations.append((share, item.get("stressIndex"), label, "maxDrift ≥0.5s",
                               sec(item.get("maxDrift"))))
        tb = num(item, "maxSeekTimebaseOffset")
        if tb > 1.0:
            violations.append((share, item.get("stressIndex"), label, "seek 后时间基偏差 >1s", sec(tb)))
        if int(num(item, "seekTimebaseJumpCount")) > 0:
            violations.append((share, item.get("stressIndex"), label, "seek 后画面时间基跳变",
                               int(num(item, "seekTimebaseJumpCount"))))

    lines = [
        "# 多磁盘轮换随机播放 / 跳转基准测试报告",
        "",
        f"- 日期：{args.date}",
        f"- 设备：{args.device}",
        f"- 主机：`{args.host}`",
        f"- 共享（磁盘）轮换顺序：{' → '.join(entry['share'] for entry in entries)}",
        f"- 构建：{args.build}",
        f"- 测试方式：每个共享独立启动一进程；随机抽取视频，播放 "
        f"{int(args.seek_after)} 秒后 seek 到 {args.seek_fraction * 100:.2f}%，再播放 "
        f"{max(1, int(args.play_seconds - args.seek_after))} 秒",
    ]
    if args.args:
        lines.append(f"- 启动参数：`{args.args}`")
    lines += [
        "",
        f"> 说明：{len(entries)} 个共享按顺序轮换执行，每个共享开始前清空续播历史并重置验收报告，"
        "因此不会跨共享复用播放记录；每个样本的路径均来自当前共享。",
        "",
        "## 总体结果",
        "",
        f"- 覆盖共享：**{len(entries)}** 个",
        f"- 完成视频：**{len(all_stress)}** 条",
        f"- 计划抽取：{' + '.join(str(s['picked']) for s in summaries)} 条",
        f"- 有效播放时长：约 {len(all_stress) * args.play_seconds / 60:.0f} 分钟；"
        f"抽样影片总时长 {sum(values(all_stress, 'durationSeconds')) / 3600:.1f} 小时",
        f"- 硬件严重问题：{serious}",
        f"- 打开失败（历史路径失效/解码器缺失等）：{len(all_open_failed)}",
        f"- 文件/内容异常（已记录）：{len(file_exceptions)}",
        f"- 环境缓冲异常（已记录）：{len(buffer_exceptions)}",
        f"- 音画同步异常：{len(all_stress) - sync_ok}（通过 {sync_ok}/{len(all_stress)}）",
        f"- 点击→首帧 ≤1.5s：{under_1500}/{len(click_first)}；"
        f"≤2s：{under_2000}/{len(click_first)}；≤5s：{under_5000}/{len(click_first)}"
        f"{click_first_note}",
        f"- seek 命中缓存：{seek_cache_hits}/{len(all_stress)}",
        f"- 字幕错误：{len(subtitle_errors)} 条",
        f"- 时间范围：{summaries[0]['started']} → {summaries[-1]['ended']}",
        "",
        "## 分磁盘结果",
        "",
    ]
    lines += table(
        ["共享", "候选", "抽取", "完成", "首帧 avg", "首帧 p90", "首帧 max",
         "同步", "seek avg", "seek max", "文件异常", "缓冲异常", "打开失败", "停止原因"],
        [[s["share"], s["candidates"], s["picked"], s["played"],
          ms(s["first_avg"]), ms(s["first_p90"]), ms(s["first_max"]),
          f"{s['sync_ok']}/{s['played']}", ms(s["seek_avg"]), ms(s["seek_max"]),
          s["file_exceptions"], s["buffer_exceptions"], s["open_failed"], s["stop"]]
         for s in summaries],
    )
    lines += [""]

    lines += ["## 启动耗时", ""]
    lines += [stat_line("播放页出现", presented, ms),
              stat_line("点击 → 首帧", click_first, ms),
              stat_line("准备（SMB + 探测 + 字幕 + 引擎）", prepare, ms),
              stat_line("容器打开", open_input, ms),
              stat_line("流信息探测", probe, ms),
              stat_line("播放开始 → 首帧", first_frame, ms),
              stat_line("打开阶段读取字节", open_bytes, lambda v: f"{int(v / 1024)}KB"),
              stat_line("容器头缓存命中率", cache_ratio, pct),
              ""]

    lines += ["## 音画同步", ""]
    lines += [stat_line("整体 maxDrift", max_drift, sec),
              stat_line("seek 后 lastSeekDrift", last_seek_drift, sec),
              stat_line("seek 完成时 lastSeekTimebaseOffset", last_seek_tb, sec),
              stat_line("seek 后 2s 内 maxSeekTimebaseOffset", seek_tb, sec),
              stat_line("有效 maxVideoOffset（排除 >10s 瞬态）", valid_offsets, sec),
              f"- maxVideoOffset >10s 的瞬态数量：{offset_transients}（显示层绑定/seek 瞬间，不参与同步判定）",
              f"- seekTimebaseJumpCount >0 的样本：{sum(1 for v in seek_tb_jumps if v > 0)}",
              f"- clockJumpCount >0 的样本：{sum(1 for v in clock_jumps if v > 0)}",
              ""]

    lines += ["## Seek 与缓冲", ""]
    lines += [stat_line("seek 延迟", seek_latency, ms),
              stat_line("seek 后新增缓冲次数", post_stalls, lambda v: f"{int(v)} 次"),
              stat_line("seek 后新增缓冲秒数", post_seconds, sec),
              stat_line("每条总缓冲次数", total_stalls, lambda v: f"{int(v)} 次"),
              stat_line("每条累计缓冲", total_seconds, sec),
              stat_line("起播后 30s 缓冲次数", startup_stalls, lambda v: f"{int(v)} 次"),
              f"- seek 命中缓存：{seek_cache_hits}/{len(all_stress)} "
              f"（首分钟跳到 50% 通常为 cache miss，命中率低属正常）",
              ""]

    if violations:
        lines += ["## 超标记录", ""] + table(
            ["共享", "#", "文件", "项", "值"], violations[:100]
        ) + [""]
    else:
        lines += ["## 超标记录", "", "无。", ""]

    if file_exceptions:
        lines += ["## 文件/内容异常", ""] + table(
            ["共享", "#", "文件", "原因", "恢复次数", "状态"],
            [[x.get("_share", ""), x.get("stressIndex"), short(x.get("path"), 40),
              x.get("stressReason", ""), int(num(x, "videoRecoveries")),
              x.get("videoStatus", "")] for x in file_exceptions],
        ) + [""]

    if all_open_failed:
        lines += ["## 打开失败", ""] + table(
            ["共享", "#", "文件", "原因"],
            [[x.get("_share", ""), x.get("stressIndex"), short(x.get("path"), 52),
              x.get("failure", "")] for x in all_open_failed],
        ) + [""]

    lines += ["## 启动最慢的 10 条", ""] + table(
        ["共享", "#", "文件", "点击→首帧", "播放页", "准备", "打开", "探测", "首帧"],
        [[x.get("_share", ""), x.get("stressIndex"), short(x.get("path"), 32),
          ms(x.get("clickToFirstVideoMilliseconds")),
          ms(x.get("playerPresentedMilliseconds")),
          ms(x.get("prepareMilliseconds")), ms(x.get("openInputMilliseconds")),
          ms(x.get("streamInfoMilliseconds")), ms(x.get("firstVideoMilliseconds"))]
         for x in sorted(all_stress,
                         key=lambda z: -num(z, "clickToFirstVideoMilliseconds"))[:10]],
    ) + [""]

    lines += ["## Seek 最慢的 10 条", ""] + table(
        ["共享", "#", "文件", "seek", "命中", "maxDrift", "时间基", "seek 后缓冲", "总缓冲"],
        [[x.get("_share", ""), x.get("stressIndex"), short(x.get("path"), 32),
          ms(x.get("lastSeekLatencyMilliseconds")), "✓" if x.get("seekCacheHit") else "✗",
          sec(x.get("maxDrift")), sec(x.get("maxSeekTimebaseOffset")),
          sec(x.get("postSeekBufferSeconds")), sec(x.get("bufferSeconds"))]
         for x in sorted(all_stress,
                         key=lambda z: -num(z, "lastSeekLatencyMilliseconds"))[:10]],
    ) + [""]

    lines += ["## 逐条明细", ""] + table(
        ["共享", "#", "文件", "启动", "准备", "打开", "探测", "首帧", "同步",
         "maxDrift", "时间基", "seek", "命中", "seek后缓冲", "总缓冲", "字幕"],
        [[x.get("_share", ""), x.get("stressIndex"), short(x.get("path"), 30),
          ms(x.get("clickToFirstVideoMilliseconds")),
          ms(x.get("prepareMilliseconds")), ms(x.get("openInputMilliseconds")),
          ms(x.get("streamInfoMilliseconds")), ms(x.get("firstVideoMilliseconds")),
          "✓" if x.get("stressSyncOK") else "✗", sec(x.get("maxDrift")),
          sec(x.get("maxSeekTimebaseOffset")),
          ms(x.get("lastSeekLatencyMilliseconds")),
          "✓" if x.get("seekCacheHit") else "✗",
          sec(x.get("postSeekBufferSeconds")), sec(x.get("bufferSeconds")),
          f"{int(num(x, 'subtitleCues'))} 条"]
         for x in all_stress],
    ) + [""]

    if args.baseline:
        comparison_rows = [
            ["本次多磁盘", "—", len(all_stress), ms(statistics.mean(click_first)) if click_first else "—",
             ms(q(click_first, 0.9)), ms(q(click_first, 0.5)),
             ms(statistics.mean(seek_latency)) if seek_latency else "—",
             sec(max(max_drift)) if max_drift else "—",
             f"{sync_ok}/{len(all_stress)}"]
        ]
        for spec in args.baseline:
            label, _, path = spec.partition("=")
            if not path:
                label, path = Path(spec).stem, spec
            try:
                data = json.load(open(path))
            except Exception:
                continue
            items = [item for item in data if item.get("reason") == "stress"]
            first = values(items, "clickToFirstVideoMilliseconds")
            seek = [v for v in values(items, "lastSeekLatencyMilliseconds") if v > 0]
            drift = abs_values(items, "maxDrift")
            ok = sum(1 for item in items if item.get("stressSyncOK") is True)
            comparison_rows.append([
                label, "—", len(items),
                ms(statistics.mean(first)) if first else "—",
                ms(q(first, 0.9)), ms(q(first, 0.5)),
                ms(statistics.mean(seek)) if seek else "—",
                sec(max(drift)) if drift else "—",
                f"{ok}/{len(items)}",
            ])
        lines += ["## 与基线对比", "",
                  "> 基线来自旧构建且测试时长/模式不同，仅作趋势参考，不作为门槛。", ""]
        lines += table(
            ["数据源", "抽取", "完成", "首帧 avg", "首帧 p90", "首帧 p50",
             "seek avg", "maxDrift 最大", "同步"],
            comparison_rows,
        ) + [""]

    lines += ["## 结论", ""]
    if not all_stress:
        lines.append("没有可分析样本。")
    elif serious:
        lines.append("存在硬件/解码严重问题，测试提前停止；详见逐条明细。")
    else:
        fastest = min(summaries, key=lambda s: s["first_avg"])
        slowest = max(summaries, key=lambda s: s["first_avg"])
        lines += [
            f"- 测试完成：{len(all_stress)} 条，无硬件严重问题；"
            f"音画同步通过 {sync_ok}/{len(all_stress)}，"
            f"seek 后时间基跳变 {sum(1 for v in seek_tb_jumps if v > 0)} 条，"
            f"超标记录 {len(violations)} 条。",
            f"- 磁盘差异：首帧平均最快 `{fastest['share']}` {ms(fastest['first_avg'])}，"
            f"最慢 `{slowest['share']}` {ms(slowest['first_avg'])}。",
            f"- 文件/内容异常 {len(file_exceptions)} 条、打开失败 {len(all_open_failed)} 条、"
            f"环境缓冲异常 {len(buffer_exceptions)} 条；均为内容/链路例外，未作为播放器回归判定。",
            f"- 首帧 ≤1.5s 占比 {under_1500}/{len(click_first)}；"
            f">5s 的样本 {sum(1 for v in click_first if v > 5000)} 条，需结合对应磁盘冷读状态复核。",
        ]
    lines += ["", "原始 JSON："]
    for entry in entries:
        lines.append(f"- `{Path(entry['path']).name}`")
    lines += ["", "复现脚本：`Scripts/run-multi-share-benchmark.sh`", ""]

    Path(args.output).write_text("\n".join(lines))
    print(f"wrote {args.output}: shares={len(entries)} entries={len(all_stress)} "
          f"violations={len(violations)} file_exceptions={len(file_exceptions)} "
          f"open_failed={len(all_open_failed)} serious={serious}")


if __name__ == "__main__":
    main()

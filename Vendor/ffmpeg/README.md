# FFmpeg（iOS 静态库）

本目录是播放内核使用的 FFmpeg 源码、构建脚本与本地 patch。`build.sh` 会：

1. 幂等应用 `patches/` 下的 patch（已应用则跳过）；
2. 分别为 `arm64-apple-ios26.0`（真机）与 `arm64-apple-ios26.0-simulator` 构建静态库；
3. 重新生成 `include/module.modulemap`，供 Swift 以 `import CFFmpeg` 使用。

## 本地 patch

### `0001-matroska-skip-font-attachments.patch`

- 目的：播放首开时跳过 matroska 字体附件负载。容器字体不再参与渲染，避免为几 MB 字体付出 SMB 读取与内存拷贝。
- 行为：新增 demuxer 选项 `skip_font_attachments`（默认 0）。仅在 `MediaReader` 的 `fastProbe` 播放首开设为 1；只跳过 `font/*`、`application/x-font-*`、`application/vnd.ms-opentype` 等字体 MIME，`image/*` 封面图仍完整保留。
- 统计：跳过的字体数量写入 `AVFormatContext.metadata["icemovie_skipped_font_count"]`，验收报告字段为 `skippedFontCount`。

## 应用与回滚

```bash
cd Vendor/ffmpeg/ffmpeg-src
git apply --check ../patches/0001-matroska-skip-font-attachments.patch   # 未应用时应成功
git apply ../patches/0001-matroska-skip-font-attachments.patch
```

`build.sh` 会自动完成上述步骤；重复执行不会重复打补丁（已应用时走 `git apply --reverse --check` 分支跳过）。

回滚：

```bash
cd Vendor/ffmpeg/ffmpeg-src
git apply --reverse ../patches/0001-matroska-skip-font-attachments.patch
cd ../../..
./Vendor/ffmpeg/build.sh
```

## 升级 FFmpeg

1. 先回滚本地 patch，或把新版本源码放到干净目录；
2. 用 `git apply --check` 检查 patch 是否能套用；
3. 若冲突，重点保留三处：`MatroskaDemuxContext` 的 `skip_font_attachments` / `current_attachment_is_font`、`ebml_parse` 的 `EBML_STR` / `EBML_BIN` 分支、`matroska_read_header` 的附件循环；
4. 重新生成 `0001-matroska-skip-font-attachments.patch` 并跑 `./build.sh`；
5. 用同时含字体与封面图的 MKV 验证：`attachmentFontBytes = 0`、`skippedFontCount > 0`、封面图仍可用。

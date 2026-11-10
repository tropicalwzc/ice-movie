# 字幕字体策略

## 结论

容器附件中的字体不再进入起播读取路径。ASS/SSA 字幕统一使用：

1. 随应用内置的 Noto Sans CJK（`SubtitleFont.builtinCJK`）；
2. libass 的 CoreText 字体提供器（`ass_set_fonts(..., "Noto Sans CJK SC", 2, ...)`）兜底系统字体。

因此，字幕组在 MKV 里附带的 `方正兰亭黑`、`浪漫雅圆` 等字体会被忽略，渲染改用系统可用的近似字体。

## 行为变化

- 打开容器时不再为字体附件付出 SMB 读取与内存拷贝；FFmpeg 的 matroska demuxer 通过 `skip_font_attachments` 只跳过字体 MIME，封面图等非字体附件仍保留。
- `SubtitleLoader` 不再调用 `attachments()` / `containerFonts()`，外挂 ASS 也不会为字体再打开一次容器。
- 字体替换后，依赖精确字宽的排版（OP/ED 特效、少量多层字幕）可能出现换行或位置偏移；对白、颜色、描边、定位仍由 libass 按脚本渲染。

## 对应规格

`openspec/specs/subtitle-rendering/spec.md` 的「字体回退」要求：

- 设备缺少脚本指定字体时，回退到内置中文字体或系统字体，中文/日文不得出现方框、乱码或空白；
- 容器字体附件不进入起播读取路径，渲染时忽略；
- 验收记录标明被忽略的字体数量与跳过的字节数；
- 封面图等非字体附件仍可用于媒体库呈现。

## 可观测

验收报告字段：`attachmentBytes`、`attachmentFontBytes`、`skippedFontCount`。启用字体跳过后，带字体附件的 MKV 应看到：

```text
attachmentFontBytes = 0
skippedFontCount > 0
attachmentBytes 仅剩封面图等非字体附件
```

## 回滚

如需恢复按容器字体渲染，需要同时：

1. 回滚 `Vendor/ffmpeg/patches/0001-matroska-skip-font-attachments.patch` 并重新构建；
2. 恢复 `SubtitleLoader` 的 `attachments()` 读取。

只做其中一步会导致“读了字体但没用于渲染”或“渲染时找不到字体”的不一致。

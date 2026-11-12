# Spec Delta

## MODIFIED Requirements

### Requirement: 标题解析与自然排序

媒体库 SHALL 从文件名中剥离发布组、分辨率、编码格式、音轨与字幕语言等标记，提取可读标题与季集编号；同一目录内的视频 SHALL 按集号进行自然排序，使第 2 集排在第 10 集之前。目录内至少两集视频共享同一解析标题且都有集号时，视频 SHALL 优先按季、集升序排列，集号顺序 MUST 覆盖文件拍摄时间；不构成多集序列的视频与图片 SHALL 继续按拍摄时间倒序。

#### Scenario: 含大量标记的文件名

- **WHEN** 文件名形如 `[LoliHouse] Tensei Shitara Slime Datta Ken 2nd Season [WebRip 1080p HEVC-10bit AAC]`
- **THEN** 展示标题 SHALL 保留作品名与季信息，并且不包含发布组、分辨率与编码标记

#### Scenario: 同目录多集排序

- **WHEN** 一个目录中同时存在第 1 集、第 2 集与第 10 集
- **THEN** 排序结果 SHALL 依次为 1、2、10，而不是按字符串比较得到的 1、10、2

#### Scenario: 多集文件名带拍摄时间

- **WHEN** 多集视频的文件名都带 `_yyyyMMddHHmmss` 拍摄时间，且时间与集号顺序不一致
- **THEN** 排序结果 SHALL 按季、集升序排列，MUST NOT 按拍摄时间倒序

#### Scenario: 单集视频与照片保持时间排序

- **WHEN** 目录只有单集视频、无法解析集号的视频或图片
- **THEN** 这些条目 SHALL 继续按拍摄时间倒序排列，不触发剧集优先排序

#### Scenario: 多部剧集混排

- **WHEN** 同一目录包含多部剧集，每部都有各自的集号
- **THEN** 视频 SHALL 先按解析标题分组，再在每组内按季、集升序排列

#### Scenario: 文件名无法解析

- **WHEN** 文件名不包含可识别的季集结构或标题信息
- **THEN** 应用 SHALL 回退展示清理后的原始文件名，不得展示空标题或占位符号

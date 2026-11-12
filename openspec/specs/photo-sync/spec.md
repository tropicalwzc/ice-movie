# photo-sync Specification

## Purpose

让用户把 iPhone 或 iPad 系统相册中的静态照片手动、增量地备份到 SMB 上标记为“照片库路径”的目录，并在媒体库内看到预览、进度、失败与结果；同步只增不删、不覆盖已有文件。

## Requirements

### Requirement: 照片库路径标记

用户 SHALL 能把当前 SMB 目录或网格中的目录标记为照片库路径；应用 SHALL 按 `host + share` 只保留一个目标，并在重启、切换目录或切换共享后保留各共享的目标；用户 SHALL 能取消标记，或标记另一个目录来替换旧目标。

#### Scenario: 标记当前目录

- **WHEN** 用户在目标目录中把当前目录标记为照片库路径
- **THEN** 应用 SHALL 保存该目标，并在当前目录显示同步入口、在父级网格中给该目录显示照片库徽标

#### Scenario: 取消标记

- **WHEN** 用户取消当前目录的照片库标记
- **THEN** 应用 SHALL 移除该目标与徽标，同步入口 MUST 消失，SMB 中已有照片 MUST NOT 被删除

#### Scenario: 替换目标

- **WHEN** 同一 `host + share` 已有一个目标，用户又标记另一个目录
- **THEN** 应用 SHALL 先说明将替换旧目标，确认后只保留新目标

#### Scenario: 重启后保留

- **WHEN** 用户重启应用并重新连接同一 `host + share`
- **THEN** 应用 SHALL 恢复该共享此前保存的照片库目标

#### Scenario: 切换共享

- **WHEN** 用户切换到另一个共享
- **THEN** 应用 SHALL 使用该共享自己的目标；当前共享没有目标时 MUST NOT 显示同步入口

### Requirement: 系统相册读取授权

首次开始同步时，应用 SHALL 请求读取系统相册的权限；权限被拒绝或受限时 SHALL 停止同步并说明原因；有限授权时 SHALL 只同步用户已授权的照片，并在预览中说明可访问数量。

#### Scenario: 允许全部照片

- **WHEN** 用户授予读取全部照片的权限
- **THEN** 应用 SHALL 继续扫描系统相册中的静态图片

#### Scenario: 拒绝权限

- **WHEN** 用户拒绝读取照片的权限
- **THEN** 应用 SHALL 停止同步、说明需要权限，并提供前往系统设置的入口

#### Scenario: 有限授权

- **WHEN** 用户只授权部分照片
- **THEN** 应用 SHALL 只扫描并可同步这些已授权照片，并在预览中标注“有限授权”

#### Scenario: 同步中权限被收回

- **WHEN** 用户在同步过程中撤销照片读取权限
- **THEN** 应用 SHALL 停止同步，并在状态条与汇总中显示权限错误

### Requirement: 静态图片同步范围

同步 SHALL 只处理系统相册中的静态图片 JPG/JPEG/PNG/HEIC/HEIF；视频、GIF/APNG/WebP、RAW/DNG SHALL 跳过并计数；隐藏照片 MUST NOT 被上传；仅存于 iCloud 的照片 MAY 按需下载，下载失败 SHALL 计入失败。

#### Scenario: 普通静态照片

- **WHEN** 系统相册中有一张 JPG、PNG 或 HEIC 照片
- **THEN** 应用 SHALL 把它纳入待同步候选

#### Scenario: 视频与不支持格式

- **WHEN** 系统相册中有一条视频、一个 GIF 或一张 RAW 照片
- **THEN** 应用 SHALL 跳过该条目并在预览或汇总中计数，MUST NOT 把它当作失败中断同步

#### Scenario: 隐藏照片

- **WHEN** 系统相册中存在被用户隐藏的照片
- **THEN** 应用 MUST NOT 扫描或上传该照片

#### Scenario: iCloud 照片

- **WHEN** 待同步照片只存在于 iCloud、本机没有完整数据
- **THEN** 应用 SHALL 按需下载后同步；下载失败 SHALL 计入失败并允许在汇总中重试

### Requirement: Live Photo 静态图

v1 遇到 Live Photo 时 SHALL 只同步其静态图，MUST NOT 上传配对视频；同步记录 SHALL 标明该条目来自 Live Photo，以便后续补全动态内容时不必重传静态图。

#### Scenario: Live Photo 同步静态图

- **WHEN** 待同步条目是 Live Photo
- **THEN** 应用 SHALL 上传其静态图，并在同步记录中标记为 `livePhotoStill`

#### Scenario: 不传配对视频

- **WHEN** 同步 Live Photo 的静态图
- **THEN** 应用 MUST NOT 上传其配对视频，也 MUST NOT 生成 `.livp` 包

#### Scenario: 已有远端动态文件

- **WHEN** 远端已存在同名同拍摄时间的 `.livp`，而本地 Live Photo 只取静态图
- **THEN** 应用 SHALL 视为已存在并跳过，MUST NOT 再上传一张重复的静态图

### Requirement: 增量匹配

应用 SHALL 以“原文件名（去扩展名）+ 拍摄时间 `yyyyMMddHHmmss`”判断远端是否已有同一照片；匹配 MUST 忽略扩展名、大小写和文件名前缀；已存在照片 MUST NOT 重复上传；远端文件被删除后 SHALL 重新上传。

#### Scenario: 完全同名

- **WHEN** 远端已有 `IMG_9399_20260505222609.jpg`，系统相册中的对应照片也生成同名文件
- **THEN** 应用 SHALL 跳过该照片

#### Scenario: 文件名带前缀

- **WHEN** 远端文件名为 `2025-02-16 210732IMG_1241_20180526143955.livp`
- **THEN** 应用 SHALL 仍能按 `IMG_1241` 与拍摄时间识别为已存在

#### Scenario: 扩展名不同

- **WHEN** 远端已有同名同拍摄时间的 `.jpg`，本次导出为 `.heic`
- **THEN** 应用 SHALL 视为同一照片并跳过

#### Scenario: 远端文件被删除

- **WHEN** 本地记录显示照片已同步，但目标目录中的对应文件已不存在
- **THEN** 应用 SHALL 重新上传该照片

#### Scenario: 已同步后编辑

- **WHEN** 一张已同步照片在系统相册中被编辑
- **THEN** 下一次同步 SHALL 跳过它，MUST NOT 覆盖远端已有文件

#### Scenario: 手机上删除照片

- **WHEN** 用户从系统相册删除一张已同步照片
- **THEN** 下一次同步 MUST NOT 删除或修改目标目录中的对应文件

### Requirement: 同步记录与恢复

应用 SHALL 记住已成功上传的照片以加速后续扫描；记录 MUST 按目标隔离；本地记录丢失时 SHALL 依靠远端文件名匹配避免整批重复上传；记录 MUST NOT 成为唯一依据，远端文件不存在时 SHALL 补传。

#### Scenario: 第二次同步

- **WHEN** 用户对同一目标再次同步且没有新照片
- **THEN** 应用 SHALL 跳过已记录照片，并显示已是最新

#### Scenario: 记录丢失

- **WHEN** 应用重装或本地记录被清除后首次同步
- **THEN** 应用 SHALL 通过远端文件名匹配跳过已有照片，MUST NOT 整批重复上传

#### Scenario: 目标隔离

- **WHEN** 用户在同一共享上把目标替换为另一个目录
- **THEN** 新目标 SHALL 使用自己的同步记录，MUST NOT 把旧目标的记录当作新目标已有文件

### Requirement: 同步预览

开始上传前，应用 SHALL 先只读扫描并展示预览计数：系统相册可访问数、动态照片数、格式不支持数、缺少拍摄时间数、目标已有或已匹配数、待同步数；在用户确认前 MUST NOT 上传任何文件；无待同步时 SHALL 显示已是最新并结束。

#### Scenario: 有待同步照片

- **WHEN** 扫描完成且存在待同步照片
- **THEN** 应用 SHALL 展示预览计数与“开始同步”入口，等待用户确认

#### Scenario: 没有待同步照片

- **WHEN** 扫描完成且没有待同步照片
- **THEN** 应用 SHALL 显示“已是最新”，MUST NOT 开始上传

#### Scenario: 取消预览

- **WHEN** 用户在预览页取消
- **THEN** 应用 MUST NOT 上传任何文件，并关闭预览

#### Scenario: 扫描失败

- **WHEN** 扫描系统相册或读取目标目录失败
- **THEN** 应用 SHALL 显示可操作的错误说明，并允许重试或取消

### Requirement: 文件命名与目录布局

上传文件 SHALL 平铺在目标目录，名称由原文件名（去扩展名）、`_`、拍摄时间 `yyyyMMddHHmmss` 与最终扩展名组成；拍摄时间 SHALL 使用照片创建时间；同一秒同名冲突时 SHALL 在时间戳前加稳定序号，且文件名末尾仍保留 14 位拍摄时间。

#### Scenario: 普通命名

- **WHEN** 照片原文件名为 `IMG_9399.HEIC`、拍摄时间为 2026-05-05 22:26:09
- **THEN** 上传文件名 SHALL 为 `IMG_9399_20260505222609.heic`

#### Scenario: 同一秒同名

- **WHEN** 两张照片的原文件名与拍摄时间都相同
- **THEN** 应用 SHALL 为后续文件生成类似 `IMG_9399_2_20260505222609.heic` 的名称，末尾仍保留拍摄时间

#### Scenario: 缺少拍摄时间

- **WHEN** 系统相册中的照片没有创建时间也没有修改时间
- **THEN** 应用 SHALL 跳过该照片并在预览或汇总中计数，MUST NOT 使用当前时间生成不稳定文件名

#### Scenario: 平铺目标目录

- **WHEN** 目标目录包含子目录
- **THEN** 应用 SHALL 把照片直接写入目标目录，MUST NOT 递归写入子目录

### Requirement: 原子上传与不覆盖

上传 SHALL 先写同目录临时文件，校验大小后再改名为最终文件；任一步失败 SHALL 清理临时文件，MUST NOT 留下半截最终文件；目标已存在同名文件时 MUST NOT 覆盖，应作为已存在或冲突跳过；同步 MUST NOT 删除或重命名目标目录中的任何既有文件。

#### Scenario: 成功上传

- **WHEN** 一张照片写入临时文件且大小校验通过
- **THEN** 应用 SHALL 把临时文件改名为最终文件，并保留目标目录中的其他文件

#### Scenario: 大小校验失败

- **WHEN** 临时文件写入后的大小与照片数据不一致
- **THEN** 应用 SHALL 删除临时文件、把该照片计为失败，并继续处理后续照片

#### Scenario: 目标已有同名文件

- **WHEN** 最终文件名在目标目录中已存在
- **THEN** 应用 MUST NOT 覆盖该文件，应跳过并计入已存在或冲突

#### Scenario: 上传中被中断

- **WHEN** 上传过程中网络中断或应用被挂起
- **THEN** 应用 MUST NOT 留下可被误认为完整照片的半截最终文件；已存在文件不得被修改

### Requirement: 同步状态条

前台扫描或上传期间，应用 SHALL 在媒体库内容区顶部固定显示状态条，展示目标目录名、已处理/总数、数量进度条、实际上传速度和取消操作；切换目录时 SHALL 保持可见，且 MUST NOT 阻塞网格滚动；沉浸式相册或全屏播放 MAY 覆盖状态条。

#### Scenario: 上传中

- **WHEN** 同步正在上传照片
- **THEN** 状态条 SHALL 显示目标目录、已处理/总数、进度条、上传速度和取消按钮

#### Scenario: 切换目录

- **WHEN** 用户在上传期间进入另一个目录
- **THEN** 状态条 SHALL 继续显示，用户可返回目标目录或点开详情查看进度

#### Scenario: 读取照片阶段

- **WHEN** 同步正在从系统相册或 iCloud 读取照片数据
- **THEN** 状态条 SHALL 显示读取阶段文案，不得把旧上传速度当作当前速度

#### Scenario: 全部成功

- **WHEN** 所有照片上传成功
- **THEN** 状态条 SHALL 短暂显示完成与数量，然后自动隐藏

#### Scenario: 存在失败

- **WHEN** 同步结束但存在失败照片
- **THEN** 状态条 SHALL 常驻显示失败数量，并提供查看详情的入口

#### Scenario: 沉浸式浏览

- **WHEN** 用户进入全屏相册或全屏播放
- **THEN** 状态条 MAY 被覆盖；退出后若同步仍在进行或存在失败，状态条 SHALL 重新出现

### Requirement: 上传速度显示

状态条 SHALL 显示本次同步的实际 SMB 上传吞吐，按最近约 3 秒的写入进度计算，使用 KB/s 或 MB/s；没有写入进度时 SHALL 显示 0 或等待状态，MUST NOT 把系统总网速或旧值当作当前速度。

#### Scenario: 稳定上传

- **WHEN** SMB 写入持续有进度
- **THEN** 状态条 SHALL 显示类似 `↑ 18.4 MB/s` 的当前上传速度

#### Scenario: 上传停滞

- **WHEN** 最近约 3 秒没有新的写入进度
- **THEN** 状态条 SHALL 显示 0 或等待网络，而不是保留旧速度

#### Scenario: 非上传阶段

- **WHEN** 应用正在读取照片、等待 iCloud 下载或等待用户确认
- **THEN** 状态条 MUST NOT 显示会误导为当前上传速度的数值

### Requirement: 同步取消

用户 SHALL 能在状态条或进度详情中取消同步；取消 SHALL 停止调度新照片，并尽量中止当前写入与清理临时文件；已成功上传的文件 SHALL 保留；结果 SHALL 显示已处理与剩余数量；下一次同步 SHALL 从剩余照片继续且不重复。

#### Scenario: 取消上传

- **WHEN** 用户在上传期间点击取消
- **THEN** 应用 SHALL 停止调度后续照片，并显示已处理与剩余数量

#### Scenario: 取消当前文件

- **WHEN** 用户取消时当前照片仍在写入
- **THEN** 应用 SHALL 尽量中止写入并清理临时文件，MUST NOT 删除已成功上传的照片

#### Scenario: 取消后再次同步

- **WHEN** 用户取消后再次点击同步
- **THEN** 应用 SHALL 从剩余照片继续，已上传照片 MUST NOT 重复上传

### Requirement: 失败提示与汇总

单张照片失败 SHALL NOT 中断整个同步；失败 SHALL 被计数并记录原因；整体失败或连续故障 SHALL 停止同步并显示常驻错误状态；结束汇总 SHALL 展示成功、失败、跳过、用时和平均速度，并 SHALL 提供重试失败照片的入口；失败 MUST NOT 被静默忽略。

#### Scenario: 单张失败继续

- **WHEN** 某张照片导出或上传失败，但后续照片仍可处理
- **THEN** 应用 SHALL 记录该失败、继续处理后续照片，并在状态条显示失败计数

#### Scenario: 整体中断

- **WHEN** SMB 连接断开且重连失败、目标目录不存在或读取权限被收回
- **THEN** 应用 SHALL 停止同步，状态条 SHALL 变红并常驻显示错误与重试入口

#### Scenario: 结束汇总

- **WHEN** 同步完成、取消或中断
- **THEN** 应用 SHALL 展示成功数、失败数、跳过数、用时与平均速度；有失败时提供失败原因列表

#### Scenario: 重试失败

- **WHEN** 用户在汇总中点击重试失败照片
- **THEN** 应用 SHALL 只重新扫描并上传仍未成功的照片，已成功照片 MUST NOT 重复上传

#### Scenario: 预检失败

- **WHEN** 开始前发现没有照片权限、目标路径不存在或目标不可写
- **THEN** 应用 SHALL 在上传前给出明确提示与可操作入口（去设置、重新标记或取消）

#### Scenario: 全部成功

- **WHEN** 所有待同步照片都成功上传
- **THEN** 汇总 SHALL 显示成功数量，MUST NOT 显示失败提示

### Requirement: 连续失败中止

当 SMB 写入连续失败达到 3 次、目标目录不可写、登录失效或照片权限被收回时，应用 SHALL 立即停止同步并显示可操作错误，MUST NOT 继续逐张重试。

#### Scenario: 连续写入失败

- **WHEN** 连续 3 张照片都因 SMB 写入失败而未能上传
- **THEN** 应用 SHALL 停止后续上传，并显示“同步中断”与失败原因

#### Scenario: 目标不可写

- **WHEN** 目标目录没有写入权限或共享变为只读
- **THEN** 应用 SHALL 停止同步，并提示检查 SMB 权限或重新标记目标

#### Scenario: 登录或权限失效

- **WHEN** SMB 登录失效或照片读取权限在同步中被收回
- **THEN** 应用 SHALL 立即停止，并提示重新连接或前往系统设置

### Requirement: 前台运行与中断恢复

同步 SHALL 只在应用前台运行时持续进行；锁屏、切到后台或被系统挂起 MAY 中断同步；中断后已上传文件 SHALL 保留，下一次同步 SHALL 从剩余照片继续且不重复；应用 MUST NOT 承诺在后台完成同步。

#### Scenario: 切到后台

- **WHEN** 用户在上传期间切换到其他应用或锁屏
- **THEN** 同步 MAY 被系统中断，应用 MUST NOT 声称仍会在后台完成

#### Scenario: 回到前台

- **WHEN** 用户回到应用且上次同步已中断
- **THEN** 应用 SHALL 显示中断状态，用户可重新开始同步

#### Scenario: 应用被杀

- **WHEN** 应用在上传过程中被系统终止
- **THEN** 已成功上传的照片 SHALL 保留，下一次同步 SHALL 通过同步记录与远端文件名跳过它们

#### Scenario: 中断后继续

- **WHEN** 用户中断后再次同步
- **THEN** 应用 SHALL 只上传剩余照片，MUST NOT 重复上传已完成照片

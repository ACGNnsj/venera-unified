<!-- DSH-FORMAT: md-v1 -->
<!-- DSH-LABELS: needs-triage -->
<!-- DSH-CREATED: 2026-10-26T18:30:00.000Z -->
# Phase 1 候选：来自 SSR / lll 的可搬件

Type: task

> 状态：候选清单，未排期。供 `docs/venera-merge-feasibility.md` §6 的 Phase 1 排序引用；先不动代码。
> 来源：`docs/venera-forks-comparison.md`「新仓可搬清单」、`.scratch/venera-new-forks/research/01-venera-ssr.md`、`02-venera-lll.md`、`04-feature-table.md`。

## 背景

unified 已过 Phase 0（`1.18.2-rc.1+237`，Flutter 3.44.3，应用身份已换）。Phase 1 的四块是 P0-1 同步、P0-2 源仓库、P0-3 迁移器、P0-4 换源/合集；SSR 与 lll 的增量与这四块的交集很小，只有 lll 的源内容与源库方向决策需要提前处理。

## 候选与优先级

| 候选 | 来源 | 代价 | 依赖 / 前置 | 建议窗口 |
| --- | --- | --- | --- | --- |
| LL-1 JM 线路与图床分流测速切换 | lll | S（纯 `.js`，零 Dart） | 先定书源托管地址 | Phase 1，搭 P0-2 的车 |
| LL-2 新增 6 个书源与站点修复 | lll | S（纯 `.js` + `index.json`） | 同上 | Phase 1，搭 P0-2 的车 |
| LL-3 书源字段类型容错 | lll | S（6 个归一化函数） | 无 | Phase 1，搭 P0-2 的车 |
| LL-4 默认源库自托管 + 一次性迁移 | lll | M（技术 S，决策不可回头） | **必须先于 P0-2 裁决**：官方库 / 自托管 / 随包内置 | Phase 1 决策项，不写代码 |
| LL-5 `tag:`/`author:` 语法 + `search.tagSearch` 下推 | lll | M（跨 5 个 Dart 文件） | P0-2 落地后 | Phase 2 |
| LL-10 追更改「章节数对比」 | lll | M（含 `chapter_count` schema 迁移） | DB 迁移方案 | Phase 2 |
| LL-13 网络连接池复用 | lll | M（unified 是流式适配器，不能照抄同步 `fetch`） | unified rhttp 层改造 | Phase 1.5 / 2 |
| LL-6 `ImageSizeProbe` 落点精度工具 | lll | S（纯函数，269 行） | 阅读器落点方案；unified 是索引跳，仅备用 | Phase 2 可选 |
| SSR-2/3/8 ACNet 2× 原生超分整链 | SSR | M（4 个 Kotlin 文件 1,036 行 + 2 条 Gradle 依赖） | `minSdk 24`、OpenCV 4.11.0 + onnxruntime 1.23.0、原生插件注册 | Phase 2 |
| SSR-4 DeOldify 上色 | SSR | M（共用原生核后增量 S–M） | 先解决权重许可；243 MB 模型 | Phase 2+，许可先行 |
| SSR-1 Anime4K v1 纯 Dart 超分 | SSR | S | 无 | 仅作回退/备选，不进主线 |
| SSR-9 端上 OCR 翻译 | SSR | XL（分支 85 个 `.kt`、113 MB 已提交模型 + 171 MB LFS + 469 MB NMT） | 分支已分叉 59/50，不含 main 修复 | **不搬**；主线翻译走 VeneraX 纯 Dart 路线 |

## 明确不搬 / 已撞车

- **LL-4 的方向冲突**：venera 把默认源拉回官方，lll 反过来自托管；unified 只能选一个方向，否则「检查更新永远没有更新」。
- **LL-11 应用内更新**：撞 prime（prime 更完整，含六平台与 AltStore），lll 这套不重复引入。
- **LL-12 快捷搜索**：撞 Next 的 `search_shortcuts`。
- **LL-7/8/9 阅读器修复**：lll 为实现跨章无缝换成像素累加 delegate，自造 6 次 A 类 bug；unified 继承 Next 的索引跳，没有对应缺陷。
- **SSR-10/11/12**：品牌删减、基线小修、版本事实，不是能力。

## 依赖关系

```text
LL-4 源库方向裁决
  └─> P0-2 源仓库
        ├─> LL-1 / LL-2 / LL-3（源内容）
        ├─> P0-4 换源/合集
        └─> LL-5（Phase 2）

P0-3 迁移器 ── 可与 P0-1 同步并行
P0-1 同步   ── 与本清单无交集
LL-13 连接池 ── 独立，Phase 1.5/2
SSR-2/3/8    ── 独立，Phase 2
```

## 前置条件清单

1. **书源托管地址**：不要个人 `master`、不要 `%20` 路径；两份目录（`book source/` 与上游）映射收敛成一套，`index.json` 只留一个入口。
2. **`minAppVersion` 门槛**：`copy_manga 1.6.0` / `jm 1.5.0` / `hitomi 1.4.6`；unified 现为 `1.18.2-rc.1+237` 可通过，但若新身份把版本重置为 `1.0.0` 会当场装不上。
3. **ACNet 资产**：模型 21,703 B 进 `pubspec`，确认包名与 `MainActivity` 注册；上色另需许可明确的权重。
4. **证据强度**：SSR 分支可构建性、lll 连接池收益、各源当前可用性均未联网/真机验证，按「自述推断」对待。

## 验收

- Phase 1 排序时能直接引用本表的「建议窗口 / 依赖」两列。
- 若决定搬 LL-1/2/3，另开实施票并引用本票；本票不直接改代码。

## 本轮复核修正（2026-10-27）

来源：`.scratch/venera-phase1/research/{03-ssr-fit,05-lll-fit}.md`，汇总在 `docs/venera-phase1-plan.md`。**上表被推翻/修正的地方以此节为准。**

| 条目 | 原说法 | 复核结果 |
| --- | --- | --- |
| LL-3 | 6 个归一化函数 | **7 个**（多 `_asDouble`），调用点 46 处；`_asTimeStr` 的 `1e10` 秒/毫秒分界要与 unified `toTimeString` 对齐 |
| LL-5 | 跨 5 个 Dart 文件 | **6 个 lib 文件**（5 改 + 1 新增 `search_query.dart`，HEAD 上已 248 行），另加 `translation.json`、2 个测试、1 份文档；整个 commit 10 文件 673+/14− |
| LL-13 | 「unified 是流式适配器，不能照抄同步 fetch」 | 理由**不完整**：真正障碍是 unified **从不把 Rust client 句柄传下去**（全仓 0 处 `RequestClient`），每请求 `resolve_client(None)` 新建 reqwest client；而 `keepAliveTimeout: 60` 已经配了却白设。所有权模型对立（`OwnedDioClient` 按操作 `close(force: true)`），只能另开句柄池 |
| LL-2 | 6 个新源可直接搬 | 其中 manwang/mhua5/kubb 上线不足一月（`44e7d2c`→`a35271c` 之间分类页是坏的），且所有 url 都是个人 `master` + `book%20source` 路径 → **只进「可选仓库」，不进默认库** |
| LL-1 | 纯 `.js` 零 Dart | 属实，但 `jm.js:19` 的 url 指向 `cdn.jsdelivr.net/gh/lll152872/venera-lll@master`（个人仓 + 分支漂移），线路硬编码要靠人跟 |
| LL-4 | 「必须先于 P0-2 裁决」 | 约束比原判更硬：unified 的「检查更新」只认有 repository origin 的源，无 origin 永久计入 `skipped`（`source_repositories.dart:446-457`）——**随包内置正好落这类**。建议方向：自托管，官方库降为 legacy 迁移源 |
| SSR-2/3/8 | 「4 个 Kotlin 文件 1,036 行」是 ACNet 专链 | 数字对、**归属错**：1,036 行是上色+超分共用的原生核（`ColorizeEngine.kt` 734 行里 ESRGAN 分块约 160 行）。Dart 侧依赖 `shared_preferences`（unified 没有），须改写为 Settings；unified 侧共 6 处落点、约 1,800 行。**体积**：裸 `.so` 单 ABI 增量 arm64 ≈42 MB、x86_64 ≈79 MB。**缺陷**：1 通道 ACNet 在部分设备 NNAPI 返回全灰 Y 且自检漏判（`7843a81` 补丁 14 分钟即被 `e05a5ba` 回滚），搬时应 `channels == 1` 强制 CPU |
| SSR-4 | 「增量 S–M，许可先行」 | 属实，但权重仓 `instant-high/deoldify-onnx` 的 GitHub `license` 字段是 `null`（DeOldify 上游 MIT 只覆盖代码），许可未定前不要写代码 |
| SSR-1 | 「Anime4K v1 纯 Dart」 | 属实可整段搬，但要注明它是**自研的 Anime4K v1 "Push Pixels" 近似实现**，不是官方实现 |
| SSR-9 | 「113 MB 已提交 + 171 MB LFS + 469 MB NMT」 | **「171 MB LFS + 469 MB NMT」不成立**：该分支整树 120.8 MB（模型 107.9 MB，含 0 字节 LFS 指针需补齐）；已分叉 main 领先 50 / 分支领先 59。仍然不搬 |
| `minSdk` | 「`minSdk 24` 是前置」 | **不是障碍**：SSR 显式写 24，unified 走 `flutter.minSdkVersion`，Flutter 3.44.3 默认就是 24 |

# 自托管 F-Droid 仓库

[返回 README](../../README.md) · 相关工作流：[fdroid-repo.yml](../../.github/workflows/fdroid-repo.yml)

仓库用一条手动工作流把已发布 Release 里的 APK 收进一个自建 F-Droid 索引，索引与 APK 落在本仓 `gh-pages` 分支的 `fdroid/repo/`，由 GitHub Pages 直接对外提供。**2026-11-08 已端到端跑通**（run 42483830585），当前索引地址：

```text
https://gallery.acgmn.asia/venera-unified/fdroid/repo
```

F-Droid 客户端里「设置 → 存储库 → 添加存储库」填上面这行即可订阅。注意本账号的 Pages 挂在自定义域 `gallery.acgmn.asia` 上，`acgnnsj.github.io` 会跳转到它，而索引里的地址必须与客户端填的一致（工作流会自动问 Pages API 取对外地址，不需要手填）。自建仓只包含本仓发布的 APK，不进入 F-Droid 官方主库；官方收录需要单独提交流程，与这里无关。

## 一次性准备：仓库签名密钥

F-Droid 索引用一套**独立的仓库签名密钥**签名，和 Android 应用的发布证书不是同一份东西，千万别混用。没配齐三个 secret 时工作流会在第一步就报错停下（空 jks 要到 `fdroid update` 才炸，那时错误信息很难读）。

```bash
# 1. 生成密钥库，有效期按需给足（例如 10000 天）
keytool -genkeypair -keystore fdroid-repo.jks -alias venera-fdroid \
  -keyalg RSA -keysize 4096 -validity 10000 -storepass '<密码>' -keypass '<密码>' \
  -dname 'CN=Venera Unified F-Droid Repo'

# 2. 转成单行 base64 供 secret 使用
base64 -w0 fdroid-repo.jks > fdroid-repo.jks.b64
```

然后在仓库 Settings → Secrets and variables → Actions 里配三个：

| Secret | 内容 |
| --- | --- |
| `FDROID_KEYSTORE_B64` | `fdroid-repo.jks.b64` 的整行内容 |
| `FDROID_KEYSTORE_PASS` | 上面 `-storepass` 的密码（`-keypass` 用同一个） |
| `FDROID_KEY_ALIAS` | `venera-fdroid` |

生成的 `fdroid-repo.jks` 请离线留存：更换密钥等于换仓库身份，老客户端会报签名不匹配，只能删库重加。

## 出一版索引

1. 先有一个能下载到 APK 的 Release。
2. Actions → 「F-Droid 自建仓」→ Run workflow，填两个输入：

   | 输入 | 填什么 |
   | --- | --- |
   | `tag` | 已发布的标签，例如 `v1.21.0` |
   | `asset` | Release 里 APK 资产名的通配符，默认 `*-android.apk` |

3. 工作流下载 APK、量体积、拉（或首次创建）`gh-pages`、跑 `fdroid update`、推回 `gh-pages`。

**为什么 `asset` 要改**：GitHub 对分支里的单个文件有 100 MiB 硬上限，而 universal 包现在 130–155 MB（v1.20.0 是 148 MB），推上去会被服务端直接拒绝。所以 universal 包超限时要改成 `*-android-arm64-v8a.apk`（约 56 MB）。工作流会在推之前量体积并给出明确报错，不会让你等到 push 阶段才看到一句 "exceeds GitHub's file size limit"。

目前自建仓按**单 ABI（arm64-v8a）**发布：分 ABI 包各自小于上限，但同一 versionCode 的多份 APK 在 fdroidserver 里不能共存成一份多 ABI 条目，所以先只收 arm64。要覆盖 armeabi-v7a / x86_64 得先把 universal 包瘦到 100 MiB 以下，或另建仓。

本地核对索引是否更新：

```bash
curl -sL https://gallery.acgmn.asia/venera-unified/fdroid/repo/index-v2.json | head -c 400
```

返回 JSON 里 `repo.address` 应与上面地址一致，`packages` 下能看到新版本的 `versionName` 与 APK 的 `file.sha256` 即为成功。GitHub Pages 有几十秒到几分钟的发布延迟，刚推完立刻 404 属正常。

## 应用信息从哪里来

客户端的名称、摘要、描述、许可证来自 `fdroid/metadata/io.github.venera.unified.yml`（随主仓版本管理）。工作流每次把它复制进 `gh-pages` 的 `fdroid/metadata/`，所以改简介只改这一个文件；`fdroid update --create-metadata` 只在完全没有 metadata 时兜底生成空骨架。

## 已知边界

- `gh-pages` 第一次不存在时工作流会建孤儿分支（先 `ls-remote` 探测，缺失才建）；此后每次都是 clone → 增量提交。旧写法 `clone ... || mkdir` 会在首跑留下一个非 git 目录，后面 `git commit` 直接失败，已修。
- fdroidserver 2.x 只读 `config.yml`，`config.py` 会被忽略（日志里只有一行 `WARNING: Ignoring deprecated config.py`），随后按默认 `keystore.p12` 找不到密钥。
- 索引与 APK 同在一个仓，APK 体积会累积在 `gh-pages` 历史里；换版本时旧 APK 还在，仓库体积只增不减，需要瘦身时另行处理，不影响索引可用性。
- 客户端安装成功与否属人工验收项，CI 不做安装测试。

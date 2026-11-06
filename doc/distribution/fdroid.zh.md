# 自托管 F-Droid 仓库

[返回 README](../../README.md) · 相关工作流：[fdroid-repo.yml](../../.github/workflows/fdroid-repo.yml)

仓库用一条手动工作流把已发布 Release 里的 universal APK 收进一个自建 F-Droid 索引，索引与 APK 落在本仓 `gh-pages` 分支的 `fdroid/repo/`，由 GitHub Pages 直接对外提供：

```text
https://acgnnsj.github.io/venera-unified/fdroid/repo
```

F-Droid 客户端里「设置 → 存储库 → 添加存储库」填上面这行即可订阅。自建仓只包含本仓发布的 APK，不进入 F-Droid 官方主库；官方收录需要单独提交流程，与这里无关。

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

1. 先有一个能下载到 APK 的 Release：里面要有 `*-android.apk` 命名的 universal 包（CI 的 Android 构建产物即此命名）。
2. Actions → 「F-Droid 自建仓」→ Run workflow，填标签（例如 `v1.21.0`）。
3. 工作流下载 APK、拉 `gh-pages`、跑 `fdroid update`、推回 `gh-pages`。

本地核对索引是否更新：

```bash
curl -sL https://acgnnsj.github.io/venera-unified/fdroid/repo/index-v2.json | head -c 400
```

返回 JSON 里能看到新版本的 `versionName` 与 APK 的 `hash` 即为成功。GitHub Pages 有几十秒到几分钟的发布延迟，刚推完立刻 404 属正常。

## 已知边界

- `gh-pages` 第一次不存在时工作流会新建目录，等于从孤儿历史起家；此后每次都是 clone → 增量提交。
- 索引与 APK 同在一个仓，APK 体积会累积在 `gh-pages` 历史里；需要瘦身时另行处理，不影响索引可用性。
- 客户端安装成功与否属人工验收项，CI 不做安装测试。

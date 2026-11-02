# Windows MSIX 与微软商店发布

`python windows/build.py` 现在额外产出三个文件，与已有的便携 zip、Inno 安装包并列，
五条路互不影响：

- `build/windows/VeneraUnified-<版本>-windows.msix`：单包，给侧载与自签名用。
- `build/windows/VeneraUnified-<版本>-windows.msixbundle`：上面那个包打成的一个 bundle。
- `build/windows/VeneraUnified-<版本>-windows.msixupload`：一个 zip，里面**只**装这个
  bundle。商店要的是这个格式；注意它不是 bundle 本身，MakeAppx 也做不出上传文件，
  必须自己 zip。

## 版本号

MSIX 只收四段纯数字版本。`pubspec.yaml` 的 `1.19.0+245` 映射为 `1.19.0.0`：
前三段取版本号，第四段固定 0。微软商店硬性要求修订号为 0，不为 0 上传会被拒
（`不允许应用在应用清单中指定版本号不为零的版本`），CI 的产物校验里也有一条同样的断言。
代价是同版本号重装需要先卸载，跨补丁版本（`1.19.0` → `1.19.1`）仍能正常覆盖升级。

## 包身份

默认值只够侧载试用，提交商店必须换成 Partner Center 分配的真实身份：

| 环境变量 | 默认 | 说明 |
| --- | --- | --- |
| `MSIX_IDENTITY_NAME` | `ACGNnsj.VeneraUnified` | 保留应用名后由 Partner Center 分配，形如 `12345ACGNnsj.VeneraUnified` |
| `MSIX_PUBLISHER` | `CN=ACGNnsj` | 形如 `CN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`，与账号绑定 |
| `MSIX_PUBLISHER_DISPLAY_NAME` | `ACGNnsj` | 商店页显示的发行方名称 |

设置环境变量后重新构建即可，`windows/appx/AppxManifest.xml` 不用改。

CI 里走仓库变量，不必改代码：Settings → Secrets and variables → Actions →
Variables 新建 `MSIX_IDENTITY_NAME`、`MSIX_PUBLISHER`、`MSIX_PUBLISHER_DISPLAY_NAME`
三条，`build.yml` 的「构建 Windows 安装包」步骤会把它们传进构建环境。变量留空时
自动回落到上面的侧载默认值，所以填之前 CI 也不会坏。

## 提交微软商店

1. 注册 Partner Center 账号（个人一次性约 19 美元，公司约 99 美元），完成身份或企业验证。
2. 在 Partner Center 预留应用名，拿到 Identity Name、Publisher 与 Publisher ID。
3. 把三个值填进仓库变量（见上），或在本地用环境变量重新跑 `python windows/build.py`。
4. 上传 `.msixupload`（zip 里装着 `.msixbundle`），商店负责代码签名。侧载才用同名的 `.msix`。
5. 为受限功能 `runFullTrust` 申请批准：桌面应用都声明了它，认证页面会提示「需要先请求
   批准」，在提交时一并勾选申请即可，不申请会卡住认证。
6. 补齐商店页素材：截图、商店 logo、隐私政策、年龄分级，然后提交认证。

注意：商店不接收未签名的侧载安装，只有提交后的商店版本才会被签名；本地安装需要下面的自签名。

## 侧载安装（自签名）

MSIX 默认不签名。要在本机装，先建自签名证书，证书 Subject 必须等于 `MSIX_PUBLISHER`：

```powershell
# 1. 自签名证书，Subject 必须与 MSIX_PUBLISHER 完全一致
$pw = Read-Host -AsSecureString
$cert = New-SelfSignedCertificate -Type Custom -Subject 'CN=ACGNnsj' `
  -KeyUsage DigitalSignature -FriendlyName 'Venera Unified MSIX' `
  -CertStoreLocation 'Cert:\CurrentUser\My'
Export-PfxCertificate -Cert "Cert:\CurrentUser\My\$($cert.Thumbprint)" -FilePath venera.pfx -Password $pw

# 2. 用 signtool 直接签 .msix（不需要先解包）
$signtool = "$env:ProgramFiles(x86)\Windows Kits\10\bin\10.0.28000.0\x64\signtool.exe"
& $signtool sign /fd SHA256 /a /f venera.pfx /p (Read-Host -AsPlainText) `
  build/windows/VeneraUnified-1.19.0-windows.msix

# 3. 信任证书后才能安装（正式分发才需要，本地测试装进当前用户即可）
Import-Certificate -FilePath (Export-Certificate -Cert $cert -FilePath venera.cer).FullName `
  -CertStoreLocation 'Cert:\CurrentUser\Root'
Add-AppxPackage build/windows/VeneraUnified-1.19.0-windows.msix
```

签名只影响本机/侧载安装，不影响商店提交——商店上传的可以是未签名包，由商店签名。

## 已知限制

- 包内图标只有一个 512x512 源图，复制成 `Square44x44Logo.png`、`Square150x150Logo.png`、
  `StoreLogo.png` 三个槽位。商店页要按 Partner Center 要求单独上传规范尺寸素材。
- 未做分语言资源包（`Assets\<lang>\`），语言跟随系统；清单里声明了 `zh-CN` 与 `en-US`。
- ARM64 走 `windows/build_arm64.py`（复用同一个 `main`），也会出 `-windows-arm64.msix`；CI 目前只跑 x64 那条。

## 商店政策风险

应用是第三方漫画源聚合阅读器，且支持成人内容源。微软商店政策 10.8（不得便利
未授权版权内容的获取）与 11（成人内容）对这类应用有明确的拒绝空间，认证被拒是
现实可能。投稿前应自行评估，不要把商店上架当成必然可达的发布渠道。
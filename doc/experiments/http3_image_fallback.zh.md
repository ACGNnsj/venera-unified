# 图片 HTTP/3 回退（#100）

## 实现范围

普通请求仍沿用 TCP／TLS 的 HTTP/1.1、HTTP/2 路径。缩略图与正文图片使用 `AppDio.forImages`，在满足以下全部条件时尝试一次 HTTP/3：

- HTTPS GET，既没有请求数据，也没有上传流。
- 原生客户端设置明确为直连，HTTP 版本选择仍为 `all`。
- 尚未收到响应头，原生错误明确属于连接阶段的 TLS EOF／连接重置。
- 原请求已经完成原生调用、取消回调和响应订阅释放，且没有清理失败或用户取消。

这是每个图片 HTTP 请求的单次回退，不是全局强制 H3，也不改变图源 `onLoadFailed` 的既有重试策略。普通 API、WebDAV、POST、下载中途断流、HTTP 状态错误、DNS 错误及证书错误不会因该策略重放。

H3 尝试使用首个请求的地址、请求头和客户端设置快照，仅更改 HTTP 版本。Cookie、Authorization、Referer、静态 DNS 覆盖与证书验证均保留；重定向继续由原有原生策略处理，包括正常的 Referer 更新和跨源敏感头隔离。当前 reqwest H3 传输不能履行普通 HTTP／SOCKS 代理设置，因此有代理或代理状态未明确时不启用回退，不能通过悄悄改走直连解决代理兼容问题。

回退响应头等待最多 5 秒；调用方的连接／接收超时或原生连接超时更短时沿用较短值。超时会取消原生工作，并仍等待其实际释放，而不是仅给 Dart Future 加超时后遗弃连接。收到响应头后，图片流继续使用原有读取和取消机制。

日志记录目标 origin、H3 尝试及响应状态／失败类型，不额外输出路径、签名查询参数、请求体或认证头。双协议失败保留原始错误和 H3 错误；资源清理失败仍独立进入原有退出／排空错误链。

## 为什么 `all` 不会自动切换到 H3

锁定的 rhttp 将 `HttpVersionPref.all` 保持为默认 reqwest 请求；显式 `http3` 才设置 `http3_prior_knowledge` 和请求的 `HTTP_3` 版本。锁定的 reqwest 0.12.28 也根据请求版本选择 H3 客户端，并没有在普通 TCP 握手失败后自动重试 QUIC。

本次复用既有异步流式原生桥接，不使用文档警告可能在 H3 下崩溃的 `RhttpClient.createSync`，也不升级 Flutter、FRB 或 Rust 依赖。

## 自动化与本机原生验证

`test/network/image_http3_fallback_test.dart` 覆盖准入、单次回退、配置保留、拒绝代理／请求体／状态码／中途断流、原请求清理屏障、回退超时、取消和清理失败。既有网络生命周期测试继续覆盖暂停／未消费的响应、上传释放及关闭后的原生排空。

原生探测使用 `tool/http3_image_probe_server.py` 和 `tool/http3_image_probe.dart`。服务只绑定 `127.0.0.1`：同一个端口的 TCP 服务收到 ClientHello 后关闭连接，UDP 服务提供真实 QUIC／HTTP/3。证书由临时测试 CA 签发，通过 DNS 覆盖访问测试域名，不修改系统信任或 hosts 文件，也不请求实际漫画图源。

2026-10-15，Windows x64、Flutter 3.41.6、现有 rhttp 原生库、aioquic 1.6.1 的结果：

| 场景 | 结果 |
|---|---|
| TCP/TLS EOF 后读取 H3 图片 | 200，响应字节与测试 PNG 一致且可解码为 1×1 像素 |
| 同源 H3 重定向 | 200，DNS 覆盖、认证头和 Cookie 保持可用 |
| 不信任临时 CA | H3 证书校验拒绝，未绕过验证 |
| H3 服务不返回响应头 | 500 ms 测试期限后取消，原生排空完成 |

Windows 复现方式（先准备当前代码对应的 `rhttp.dll`；以下假定已有 Release 构建）：

```powershell
# 终端一：测试依赖仅安装到忽略的 build 目录，不进入应用依赖。
python -m pip install --target build/http3-probe-deps aioquic==1.6.1
$env:PYTHONPATH = (Join-Path (Get-Location) 'build/http3-probe-deps')
python tool/http3_image_probe_server.py --state build/http3-local-probe/state.json
```

```powershell
# 终端二：等待服务输出 ready，再运行探测。
$env:PATH = (Join-Path (Get-Location) 'build/windows/x64/runner/Release') + ';' + $env:PATH
$env:HTTP3_PROBE_STATE = (Join-Path (Get-Location) 'build/http3-local-probe/state.json')
flutter test --no-pub tool/http3_image_probe.dart
```

结束后停止终端一的测试服务。未设置 `HTTP3_PROBE_STATE` 时探测会跳过，普通测试和应用构建不依赖 Python／aioquic。

## 尚需真实环境验收

- 在反馈者的 Windows 设备上，用相同 DNS、代理设置及 URL 复测，检查新增 H3 日志；本机受控协议实验不代表原图源或问题网络已验证修复。
- 不支持 H3、UDP 不通或仅重定向目标支持 H3 的站点仍可能失败；本次没有加入 HTTPS DNS 记录／Alt-Svc 发现、主机协议缓存或全局 H3 偏好。
- HTTP/3 的成功不证明 TCP 失败必然由 SNI 过滤引起。QUIC Initial 的密钥可以推导，不能把 HTTP/3 本身当作隐藏 SNI 的保证；SNI 隐私还涉及 ECH 等机制。

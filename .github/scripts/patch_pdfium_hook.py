#!/usr/bin/env python3
"""让 pdfium_dart 的构建 hook 在离线环境里可用。

pdfium_dart 的 hook/build.dart 在 linux 构建期会用 HTTP 拉 pdfium 归档；Flatpak 的
构建沙箱没有网络，这一步必然失败。这里给 hook 打一个幂等补丁：优先用环境变量
PDFIUM_PREBUILT（缺省 /app/pdfium/lib/libpdfium.so，即 Flatpak 清单里的位置）指向的
本地库复制到 hook 期望的输出位置，不再下载；找不到本地库时打印原因再退回下载，
方便在构建日志里定位。补丁只改缓存的第三方代码，产物与联网时一致（同一个 pdfium 构建）。
"""

import sys
from pathlib import Path

MARKER = 'PDFIUM_PREBUILT'
ANCHOR = '  if (await output.exists()) return;\n'
PATCH = ANCHOR + (
    "  final prebuilt = Platform.environment['PDFIUM_PREBUILT'] ??\n"
    "      '/app/pdfium/lib/libpdfium.so';\n"
    "  print('pdfium_dart hook: prebuilt=' + prebuilt +\n"
    "      ' exists=' + File(prebuilt).existsSync().toString());\n"
    "  if (File(prebuilt).existsSync()) {\n"
    "    await output.parent.create(recursive: true);\n"
    "    await File(prebuilt).copy(output.path);\n"
    "    return;\n"
    "  }\n"
    "  print('pdfium_dart hook: 本地库不存在，退回联网下载');\n"
)


def main(argv):
    if len(argv) != 2:
        raise SystemExit('usage: patch_pdfium_hook.py <hook/build.dart>')
    path = Path(argv[1])
    text = path.read_text(encoding='utf-8')
    if MARKER in text:
        print(f'already patched: {path}')
        return 0
    if ANCHOR not in text:
        raise SystemExit(f'anchor not found in {path}')
    path.write_text(text.replace(ANCHOR, PATCH, 1), encoding='utf-8')
    print(f'patched: {path}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

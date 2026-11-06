#!/usr/bin/env python3
"""让 sqlite3 的构建 hook 在离线环境里可用。

sqlite3 的 hook 在 linux 构建期会去 GitHub Releases 拉预编译库
(https://github.com/simolus3/sqlite3.dart/releases/download/<tag>/libsqlite3.x64.linux.so)，
Flatpak 的构建沙箱没有网络，这一步必然失败。这里给 hook 打一个幂等补丁：
环境变量 SQLITE3_PREBUILT 指向同一个发布资产（工作流里已下好并校验过 sha256），
直接复制到 hook 期望的下载位置，不再联网。
"""

import sys
from pathlib import Path

MARKER = 'SQLITE3_PREBUILT'
ANCHOR = "    final tmp = File('${downloadedFile.path}.tmp');\n"
PATCH = (
    "    final prebuilt = Platform.environment['SQLITE3_PREBUILT'];\n"
    "    print('sqlite3 hook: prebuilt=' + (prebuilt ?? '<unset>'));\n"
    "    if (prebuilt != null && prebuilt.isNotEmpty) {\n"
    "      await File(prebuilt).copy(downloadedFile.path);\n"
    "      return downloadedFile;\n"
    "    }\n"
    "    print('sqlite3 hook: 没有本地库，退回联网下载');\n"
) + ANCHOR


def main(argv):
    if len(argv) != 2:
        raise SystemExit('usage: patch_sqlite3_hook.py <lib/src/hook/compile/description.dart>')
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

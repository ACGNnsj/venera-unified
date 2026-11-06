#!/usr/bin/env python3
"""让 sqlite3 的构建 hook 在离线环境里可用。

sqlite3 的 hook 在 linux 构建期会去 GitHub Releases 拉预编译库
(https://github.com/simolus3/sqlite3.dart/releases/download/<tag>/libsqlite3.x64.linux.so)，
Flatpak 的构建沙箱没有网络，这一步必然失败。这里给 hook 打一个幂等补丁：把预置库的绝对路径
（由 stage_sqlite3_asset.py 按包版本下好、放进 /app/sqlite3/<版本>/）写进 hook，
直接复制到 hook 期望的下载位置，不再联网。每个缓存里的 sqlite3 版本各自打自己的路径，
这样离线解析出哪个版本都能命中。
"""

import re
import sys
from pathlib import Path

MARKER = 'SQLITE3_PREBUILT_LOCAL'
ANCHOR = "    final tmp = File('${downloadedFile.path}.tmp');\n"
ASSET = 'libsqlite3.x64.linux.so'


def version_of(hook: Path) -> str:
    match = re.search(r'sqlite3-([^\\/]+)', str(hook))
    if not match:
        raise SystemExit(f'路径里没有 sqlite3 版本号: {hook}')
    return match.group(1)


def main(argv):
    if len(argv) != 3:
        raise SystemExit('usage: patch_sqlite3_hook.py <description.dart> <asset-dir>')
    hook = Path(argv[1])
    asset_dir = argv[2].rstrip('/')
    version = version_of(hook)
    prebuilt = f'{asset_dir}/{version}/{ASSET}'
    text = hook.read_text(encoding='utf-8')
    if MARKER in text:
        print(f'already patched: {hook}')
        return 0
    if ANCHOR not in text:
        raise SystemExit(f'anchor not found in {hook}')
    patch = (
        f"    final prebuilt = '{prebuilt}';\n"
        "    print('sqlite3 hook: prebuilt=' + prebuilt);\n"
        "    if (File(prebuilt).existsSync()) {\n"
        "      await File(prebuilt).copy(downloadedFile.path);\n"
        "      return downloadedFile;\n"
        "    }\n"
        "    print('sqlite3 hook: 本地库不存在，退回联网下载');\n"
    ) + ANCHOR
    hook.write_text(text.replace(ANCHOR, patch, 1), encoding='utf-8')
    print(f'patched: {hook} -> {prebuilt}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

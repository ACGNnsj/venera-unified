#!/usr/bin/env python3
"""把 sqlite3 包索要的预编译库下到本地目录，供离线构建复用。

sqlite3 的 hook 会按 asset_hashes.dart 里的 releaseTag 与文件名去 GitHub Releases 下载
预编译库。这里遍历 pub 缓存里出现的每个 sqlite3 版本，解析同一份清单，取出 linux x64 的
文件名、哈希与发布标签，下载并校验，落到 <stage>/sqlite3/<版本>/libsqlite3.x64.linux.so。
清单再把整个目录放进 engine-artifacts 归档，打补丁后的 hook 按版本取用。
"""

import hashlib
import re
import sys
import urllib.request
from pathlib import Path

ASSET = 'libsqlite3.x64.linux.so'
URL = 'https://github.com/simolus3/sqlite3.dart/releases/download/{tag}/{asset}'


def stage_one(package_dir: Path, stage: Path) -> None:
    version = package_dir.name.split('sqlite3-', 1)[1]
    hashes = package_dir / 'lib' / 'src' / 'hook' / 'asset_hashes.dart'
    if not hashes.is_file():
        raise SystemExit(f'{package_dir} 里没有 asset_hashes.dart')
    text = hashes.read_text(encoding='utf-8')
    tag_match = re.search(r"releaseTag = '([^']+)'", text)
    hash_match = re.search(r"'" + re.escape(ASSET) + r"': '([0-9a-f]{64})'", text)
    if not tag_match or not hash_match:
        raise SystemExit(f'解析不出 {package_dir.name} 的发布标签或 {ASSET} 哈希')
    tag, expected = tag_match.group(1), hash_match.group(1)
    url = URL.format(tag=tag, asset=ASSET)
    print(f'sqlite3 {version}: {url}')
    data = b''
    for attempt in range(1, 4):
        try:
            request = urllib.request.Request(url, headers={'User-Agent': 'venera-flatpak-vendor'})
            with urllib.request.urlopen(request) as response:
                data = response.read()
            break
        except Exception as error:  # noqa: BLE001 - 网络抖动重试三次
            print(f'第 {attempt} 次下载失败：{error}')
            if attempt == 3:
                raise
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise SystemExit(f'{ASSET} 的 sha256 是 {actual}，期望 {expected}')
    target = stage / 'sqlite3' / version / ASSET
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    print(f'staged {target} ({len(data)} bytes, sha256 {actual})')


def main(argv):
    if len(argv) != 3:
        raise SystemExit('usage: stage_sqlite3_asset.py <pub-cache> <stage-dir>')
    pub_cache = Path(argv[1])
    stage = Path(argv[2])
    packages = sorted(p for p in pub_cache.glob('hosted/*/sqlite3-*') if p.is_dir())
    if not packages:
        raise SystemExit('pub 缓存里没有 sqlite3 包')
    for package_dir in packages:
        stage_one(package_dir, stage)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

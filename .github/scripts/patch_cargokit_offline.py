"""给 cargokit 的 run_build_tool.sh 加上 --offline。

发布标签（v1.20.0）里的 cargokit 还不认识 CARGOKIT_PUB_OFFLINE，而 Flatpak 构建沙箱没有网络，
cargokit 现跑的 `dart pub get --no-precompile` 会直接 socket 报错。

幂等：已经带 --offline 的文件原样保留。
"""

from __future__ import annotations

import sys
from pathlib import Path

NEEDLE = "pub get --no-precompile"


def patch(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if "--no-precompile --offline" in text:
        print(f"cargokit: {path} 已经离线")
        return False
    if NEEDLE not in text:
        print(f"cargokit: {path} 里找不到 pub get，跳过")
        return False
    path.write_text(text.replace(NEEDLE, f"{NEEDLE} --offline"), encoding="utf-8")
    print(f"cargokit: {path} 已改走 --offline")
    return True


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: patch_cargokit_offline.py <run_build_tool.sh> [...]", file=sys.stderr)
        return 2
    for raw in argv[1:]:
        path = Path(raw)
        if not path.is_file():
            print(f"cargokit: {path} 不存在，跳过")
            continue
        patch(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

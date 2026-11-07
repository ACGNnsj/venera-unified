"""把多次 cargo vendor 打印的 source 替换配置合并成一份。

应用自己的 Rust 工作区与插件自带的 crate（例如 super_native_extensions，它依赖一个
git 源分支上的 mime_guess）各自 vendor 到同一个目录，配置里除 crates-io 之外还会有
若干 `[source."git+..."]` 段，这里按段去重合并。
"""

from __future__ import annotations

import sys
from pathlib import Path

TARGET_DIRECTORY = "/run/build/venera-unified/vendor"


def parse_sections(text: str) -> "dict[str, list[str]]":
    sections: "dict[str, list[str]]" = {}
    current = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("[") and line.endswith("]"):
            current = line
            sections.setdefault(current, [])
            continue
        if current is None:
            continue
        if not line.strip():
            continue
        sections[current].append(line)
    return sections


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: merge_vendor_config.py <out> <config> [<config> ...]", file=sys.stderr)
        return 2
    out = Path(argv[1])
    merged: "dict[str, list[str]]" = {}
    order: list[str] = []
    for raw in argv[2:]:
        path = Path(raw)
        if not path.is_file():
            continue
        for name, body in parse_sections(path.read_text(encoding="utf-8")).items():
            if name not in merged:
                merged[name] = []
                order.append(name)
            for line in body:
                if line not in merged[name]:
                    merged[name].append(line)

    if "[source.vendored-sources]" not in merged:
        print("merge: 输入里没有 [source.vendored-sources]", file=sys.stderr)
        return 1
    merged["[source.vendored-sources]"] = [f'directory = "{TARGET_DIRECTORY}"']

    def rank(name: str) -> tuple[int, str]:
        if name == "[source.crates-io]":
            return (0, name)
        if name == "[source.vendored-sources]":
            return (2, name)
        return (1, name)

    chunks = []
    for name in sorted(order, key=rank):
        chunks.append(name)
        chunks.extend(merged[name])
        chunks.append("")
    out.write_text("\n".join(chunks).rstrip() + "\n", encoding="utf-8")
    print(f"merge: 写了 {len(order)} 个 source 段 -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

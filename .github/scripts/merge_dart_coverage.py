#!/usr/bin/env python3
"""Merge sharded Dart LCOV reports into one line-coverage report."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def merge_reports(paths: list[Path]) -> dict[str, dict[int, int]]:
    """Return {source file: {line: hit count}} with counts maxed across shards."""
    merged: dict[str, dict[int, int]] = {}
    for path in paths:
        source: str | None = None
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            if raw_line.startswith("SF:"):
                source = raw_line[3:].strip()
                if not source:
                    raise ValueError(f"Empty SF record in {path}")
                merged.setdefault(source, {})
                continue
            if raw_line == "end_of_record":
                source = None
                continue
            if not raw_line.startswith("DA:"):
                continue
            if source is None:
                raise ValueError(f"DA record outside a source file in {path}: {raw_line}")
            fields = raw_line[3:].split(",")
            if len(fields) < 2:
                raise ValueError(f"Invalid LCOV line record: {raw_line}")
            try:
                line_number = int(fields[0])
                count = int(fields[1])
            except ValueError as error:
                raise ValueError(f"Invalid LCOV line record: {raw_line}") from error
            lines = merged[source]
            previous = lines.get(line_number, 0)
            # 同一行在某分片里被执行过就算命中，取较大值而不是相加，
            # 否则两片都覆盖的行会把命中数翻倍、总行数也会被重复计。
            lines[line_number] = max(previous, count)
    return merged


def write_report(merged: dict[str, dict[int, int]], output: Path) -> None:
    blocks = []
    for source in sorted(merged):
        lines = merged[source]
        if not lines:
            continue
        body = [f"SF:{source}"]
        body.extend(f"DA:{line},{lines[line]}" for line in sorted(lines))
        body.append("end_of_record")
        blocks.append("\n".join(body))
    if not blocks:
        raise ValueError("Merged report does not contain line coverage records")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(blocks) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("inputs", nargs="+", type=Path)
    args = parser.parse_args()

    missing = [str(path) for path in args.inputs if not path.is_file()]
    if missing:
        print(f"缺少分片覆盖率文件: {', '.join(missing)}", file=sys.stderr)
        return 1

    merged = merge_reports(args.inputs)
    write_report(merged, args.output)
    hit = sum(1 for lines in merged.values() for count in lines.values() if count > 0)
    total = sum(len(lines) for lines in merged.values())
    print(f"合并 {len(args.inputs)} 份分片报告：{hit}/{total} 行命中")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

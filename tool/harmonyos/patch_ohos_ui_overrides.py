#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 flutter_ohos 3.47.7 预览线打 material_ui/cupertino_ui 本地 override。

背景: 该分支的 TargetPlatform 新增了 ohos 枚举值, 导致 pub 上的
material_ui-1.2.0 / cupertino_ui-1.0.2 里所有穷尽式 switch(无 default) 报
168 个非穷尽错误。本仓 lib/ 零处, 只需修这两个包。

做法(可重复跑, 幂等):
  1. 把两个包从 PUB_CACHE 原样拷到 VENDOR_DIR(每次先删干净重拷,
     绝不动 pub cache 本体);
  2. 只在 switch 块内做三处行级改写, 把 ohos 并到 android 那一臂
     (ohos 行为取 android 同款, 与上游 HarmonyOS 分支口径一致):
       TargetPlatform.android ||      ->  后面加一行 TargetPlatform.ohos ||
       TargetPlatform.android =>  X    ->  TargetPlatform.android || TargetPlatform.ohos => X
       case TargetPlatform.android:   ->  后面加一行 case TargetPlatform.ohos:
  3. 给 APP_DIR/pubspec.yaml 补 dependency_overrides 指到 vendor 路径。

用法:
  python tool/harmonyos/patch_ohos_ui_overrides.py [--pub-cache DIR]
      [--vendor-dir DIR] [--app-dir DIR]
"""
import argparse
import re
import shutil
import sys
from pathlib import Path

PKGS = ("material_ui-1.2.0", "cupertino_ui-1.0.2")
SHORT = {"material_ui-1.2.0": "material_ui", "cupertino_ui-1.0.2": "cupertino_ui"}

RE_ARM_OR = re.compile(r"TargetPlatform\.android(\s*\|\|)(?=\s*(?:TargetPlatform\.|=>|$))")
RE_ARM_FAT = re.compile(r"^(\s*)TargetPlatform\.android(\s*=>.*)$")
RE_CASE = re.compile(r"^(\s*)case\s+TargetPlatform\.android(\s*:.*)$")
RE_SWITCH_OPEN = re.compile(r"\bswitch\b.*\{")


def patch_file(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if "TargetPlatform.ohos" in text:
        return {"or": 0, "fat": 0, "case": 0, "skipped": True}
    out = []
    depth = 0
    switch_stack = []
    stats = {"or": 0, "fat": 0, "case": 0, "skipped": False}
    for line in text.splitlines(keepends=True):
        code = line.split("//", 1)[0]
        if RE_SWITCH_OPEN.search(code):
            switch_stack.append(depth + code.count("{") - code.count("}"))
        in_switch = bool(switch_stack)
        nl = "\n" if line.endswith("\n") else ""
        body = line.rstrip("\n")
        done = False
        if in_switch:
            m = RE_ARM_OR.search(body)
            if m:
                out.append(body[:m.start()] + "TargetPlatform.android || TargetPlatform.ohos ||" + body[m.end():] + nl)
                stats["or"] += 1
                done = True
            else:
                m = RE_ARM_FAT.match(body)
                if m:
                    out.append(f"{m.group(1)}TargetPlatform.android || TargetPlatform.ohos{m.group(2)}" + nl)
                    stats["fat"] += 1
                    done = True
                else:
                    m = RE_CASE.match(body)
                    if m:
                        out.append(body + nl)
                        out.append(f"{m.group(1)}case TargetPlatform.ohos:" + nl)
                        stats["case"] += 1
                        done = True
        if not done:
            out.append(line)
        depth += code.count("{") - code.count("}")
        while switch_stack and depth < switch_stack[-1]:
            switch_stack.pop()
    if stats["or"] + stats["fat"] + stats["case"]:
        path.write_text("".join(out), encoding="utf-8")
    return stats


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pub-cache", default=r"D:\venera\.scratch\pubcache")
    ap.add_argument("--vendor-dir", default=r"D:\venera\.scratch\harmony\vendor")
    ap.add_argument("--app-dir", default=r"D:\venera\.scratch\harmony\app")
    a = ap.parse_args()
    pub_cache = Path(a.pub_cache) / "hosted" / "pub.dev"
    vendor = Path(a.vendor_dir)
    vendor.mkdir(parents=True, exist_ok=True)
    total = {"or": 0, "fat": 0, "case": 0}
    for pkg in PKGS:
        src = pub_cache / pkg
        if not src.is_dir():
            print(f"MISS: {src} 不存在", flush=True)
            return 1
        dst = vendor / pkg
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst)
        files = sorted((dst / "lib").rglob("*.dart"))
        touched = 0
        for f in files:
            st = patch_file(f)
            if st["or"] + st["fat"] + st["case"]:
                touched += 1
                for k in total:
                    total[k] += st[k]
        print(f"{pkg}: 改了 {touched} 个文件", flush=True)
    print(f"TOTAL or={total['or']} fat={total['fat']} case={total['case']}", flush=True)
    if sum(total.values()) == 0:
        print("一个都没改中,  patterns 可能对不上, 停。", flush=True)
        return 1
    # pdfium_dart: hook 在 OHOS 上既编不出 gate C 库(无 pthread.h) 也下不到
    # 预编译包, 且 PDF 导入本就是上游 HarmonyOS 分支的 unavailable 项, 直接跳过。
    pdfium_pkg = "pdfium_dart-0.4.1"
    psrc = pub_cache / pdfium_pkg
    if not psrc.is_dir():
        print(f"MISS: {psrc} 不存在", flush=True)
        return 1
    pdst = vendor / pdfium_pkg
    if pdst.exists():
        shutil.rmtree(pdst)
    shutil.copytree(psrc, pdst)
    hook = pdst / "hook" / "build.dart"
    htext = hook.read_text(encoding="utf-8")
    marker = "// ohos: skip native pdfium"
    if marker not in htext:
        anchor = "if (!input.config.buildCodeAssets) return;"
        assert anchor in htext, "pdfium hook anchor 对不上"
        htext = htext.replace(
            anchor,
            anchor
            + "\n    // ohos: flutter tool passes OS.linux shim but with the OHOS clang;"
            + "\n    // gate C lib + prebuilt download both don't apply (PDF unavailable on OHOS)."
            + "\n    final ohosCc = input.config.code.cCompiler?.compiler.toFilePath() ?? '';"
            + "\n    if (ohosCc.contains('openharmony')) return;",
            1,
        )
        hook.write_text(htext, encoding="utf-8")
        print("pdfium hook 已打 ohos 跳过", flush=True)
    else:
        print("pdfium hook 已有 ohos 跳过, 跳过", flush=True)
    # sqlite3: hook 在 OHOS 上是 linux-shim 配置, 默认下 glibc 预编译 .so。
    # 本仓用 build_native_ohos.py --component sqlite 以 OHOS clang 直编进
    # entry/libs, hook 只声明 source: system 做运行时 dlopen。
    SHORT[pdfium_pkg] = "pdfium_dart"
    PKGS2 = PKGS + (pdfium_pkg,)
    # dev_dependencies 里的 integration_test 会让 flutter tool 为它生成独立
    # ohos module 并塞进 .hvigor/dependencyMap；ohpm i --all 的解析闭包随之
    # 爆炸（实测 Node 堆 32GB 也 OOM、跑 6h28m 才挂）。阅读器 HAP 不需要测试
    # 模块，删掉它能把构建时间压到约 8 分钟。
    _pubspec = Path(a.app_dir) / "pubspec.yaml"
    _spec = _pubspec.read_text(encoding="utf-8")
    _it = """  integration_test:
    sdk: flutter
"""
    if _it in _spec:
        _pubspec.write_text(_spec.replace(_it, "", 1), encoding="utf-8")
        print("app pubspec 已移除 integration_test（ohpm 闭包爆炸根因）", flush=True)
    # path_provider 在 OHOS 上无官方实现, federated 的 openharmony-tpc 包补上
    # ohos 实现, 否则首屏 _App.init 直接 MissingPluginException。
    _spec2 = _pubspec.read_text(encoding="utf-8")
    if "path_provider_ohos:" not in _spec2:
        anchor = "  path_provider: ^2.1.6\n"
        assert anchor in _spec2, "path_provider 锚点对不上"
        _pubspec.write_text(_spec2.replace(anchor, anchor + "  path_provider_ohos: ^2.2.1\n", 1), encoding="utf-8")
        print("app pubspec 已补 path_provider_ohos（ohos federated 实现）", flush=True)
    else:
        print("app pubspec 已含 path_provider_ohos, 跳过", flush=True)
    # sqlite3 .so 由 build_native_ohos.py --component sqlite 直编进 entry/libs,
    # hook 只声明 source: system 做运行时 dlopen。
    _spec3 = _pubspec.read_text(encoding="utf-8")
    if "source: system" not in _spec3:
        _anchor = "dependency_overrides:"
        assert _anchor in _spec3, "dependency_overrides 锚点对不上"
        _hooks = "hooks:\n  user_defines:\n    sqlite3:\n      source: system\n\n"
        _pubspec.write_text(_spec3.replace(_anchor, _hooks + _anchor, 1), encoding="utf-8")
        print("app pubspec 已补 sqlite3 hooks user_defines（source: system）", flush=True)
    else:
        print("app pubspec 已含 sqlite3 hooks user_defines, 跳过", flush=True)
    # flutter_rust_bridge: 默认 loader 不认识 ohos(Platform.operatingSystem),
    # 直接 throw。vendor 后把 ohos 并到 android 分支(dlopen 包内 .so)。
    frb_pkg = "flutter_rust_bridge-2.11.1"
    frb_src = pub_cache / frb_pkg
    if not frb_src.is_dir():
        print(f"MISS: {frb_src} 不存在", flush=True)
        return 1
    frb_dst = vendor / frb_pkg
    if frb_dst.exists():
        shutil.rmtree(frb_dst)
    shutil.copytree(frb_src, frb_dst)
    frb_loader = frb_dst / "lib" / "src" / "loader" / "_io.dart"
    frb_text = frb_loader.read_text(encoding="utf-8")
    frb_marker = "// ohos: treat like android"
    if frb_marker not in frb_text:
        frb_anchor = "  if (Platform.isAndroid) {"
        assert frb_anchor in frb_text, "frb loader 锚点对不上"
        frb_text = frb_text.replace(
            frb_anchor,
            "  " + frb_marker + ", dlopen the bundled .so by soname.\n"
            "  if (Platform.isAndroid || Platform.operatingSystem == 'ohos') {", 1)
        frb_loader.write_text(frb_text, encoding="utf-8")
        print("frb loader 已补 ohos 分支", flush=True)
    else:
        print("frb loader 已有 ohos 分支, 跳过", flush=True)
    _spec5 = _pubspec.read_text(encoding="utf-8")
    _frb_pin = "dependency_overrides:\n  flutter_rust_bridge: 2.11.1\n"
    _frb_path = ("dependency_overrides:\n  flutter_rust_bridge:\n"
                 "    path: D:/venera/.scratch/harmony/vendor/flutter_rust_bridge-2.11.1\n")
    if _frb_pin in _spec5:
        _pubspec.write_text(_spec5.replace(_frb_pin, _frb_path, 1), encoding="utf-8")
        print("app pubspec flutter_rust_bridge 已切 vendor path", flush=True)
    else:
        print("app pubspec flutter_rust_bridge override 已就绪, 跳过", flush=True)
    # flutter_qjs + flutter_7zip: 两家 _dylib/_qjsLib switch 都不认 ohos
    # (Platform.operatingSystem), 直接 throw Unknown platform。qjs 的 libqjs.so 与
    # 7zip 的 libflutter_7zip.so 都由 build_native_ohos.py 以 OHOS clang 直编进
    # entry/libs, 这里 vendor 后把 ohos 并到 android 分支（按 soname dlopen 包内 .so）。
    _git = Path(a.pub_cache) / "git"
    _ohos_dart = [
        ("flutter_qjs-295f77421eedff356a02e92987181b525970c780", "flutter_qjs-295f774",
         "lib/src/ffi.dart", "  if (Platform.isAndroid) {", "libqjs.so"),
        ("flutter_7zip-b33344797f1d2469339e0e1b75f5f954f1da224c", "flutter_7zip-b333447",
         "lib/flutter_7zip.dart", "  if (Platform.isAndroid || Platform.isLinux) {", "libflutter_7zip.so"),
    ]
    _spec6 = _pubspec.read_text(encoding="utf-8")
    for _gsrc, _gdst, _gfile, _ganchor, _gsoname in _ohos_dart:
        _gsrcp = _git / _gsrc
        if not _gsrcp.is_dir():
            print(f"MISS: {_gsrcp} 不存在", flush=True)
            return 1
        _gdstp = vendor / _gdst
        if _gdstp.exists():
            shutil.rmtree(_gdstp)
        shutil.copytree(_gsrcp, _gdstp, ignore=shutil.ignore_patterns(".git"))
        _gf = _gdstp / _gfile
        _gt = _gf.read_text(encoding="utf-8")
        _gmarker = "// ohos: treat like android"
        if _gmarker not in _gt:
            assert _ganchor in _gt, f"{_gdst} dylib 锚点对不上"
            _gt = _gt.replace(_ganchor,
                "  " + _gmarker + ", dlopen the bundled .so by soname.\n"
                + _ganchor.replace(") {", " || Platform.operatingSystem == 'ohos') {", 1), 1)
            _gf.write_text(_gt, encoding="utf-8")
            print(f"{_gdst} dylib 已补 ohos 分支", flush=True)
        _gline = f"  {_gdst.rsplit('-', 1)[0]}:\n    path: {(_gdstp).as_posix()}\n"
        if _gline not in _spec6:
            _ov = "dependency_overrides:"
            assert _ov in _spec6
            _spec6 = _spec6.replace(_ov, _ov + "\n" + _gline, 1)
            print(f"app pubspec 已补 {_gdst} override", flush=True)
    _pubspec.write_text(_spec6, encoding="utf-8")
    pubspec = Path(a.app_dir) / "pubspec.yaml"
    spec = pubspec.read_text(encoding="utf-8")
    block = []
    for pkg in PKGS2:
        line = f"  {SHORT[pkg]}:\n    path: {(vendor / pkg).as_posix()}\n"
        if SHORT[pkg] + ":" in spec:
            print(f"pubspec 已含 {SHORT[pkg]}, 跳过", flush=True)
            continue
        block.append(line)
    if block:
        lines = spec.split("\n")
        try:
            i = next(n for n, ln in enumerate(lines) if ln.strip() == "dependency_overrides:")
        except StopIteration:
            lines.append("")
            lines.append("dependency_overrides:")
            i = len(lines) - 1
        j = i + 1
        while j < len(lines) and (lines[j].startswith("  ") or not lines[j].strip()):
            j += 1
        lines[j:j] = ("".join(block)).rstrip("\n").split("\n")
        spec = "\n".join(lines)
        pubspec.write_text(spec, encoding="utf-8")
        print("pubspec dependency_overrides 已补", flush=True)
    # 复查: vendor 里还有 android 臂没配 ohos 兄弟的 switch 行
    left = []
    for pkg in PKGS:
        for f in sorted((vendor / pkg / "lib").rglob("*.dart")):
            for i, ln in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                s = ln.strip()
                if s.startswith("TargetPlatform.android") or s.startswith("case TargetPlatform.android"):
                    left.append(f"{f.name}:{i}:{s[:60]}")
    print(f"REMAIN android-arm lines={len(left)}", flush=True)
    for ln in left[:20]:
        print("  " + ln, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

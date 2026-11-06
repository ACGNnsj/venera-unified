#!/usr/bin/env python3
"""把 flatpak/manifest.template.yml 渲染成可直接交给 flatpak-builder 的 manifest。

只依赖标准库：Flutter SDK 的 sha256 优先从官方 releases_linux.json 现取，
取不到时回落到 flatpak/flutter-sha256.json 里缓存的版本号。
"""

import argparse
import hashlib
import json
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / 'flatpak' / 'manifest.template.yml'
DEFAULT_OUTPUT = ROOT / 'flatpak' / 'io.github.venera.unified.yml'
SHA_CACHE = ROOT / 'flatpak' / 'flutter-sha256.json'
RELEASES_URL = 'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json'
RELEASE_BASE = 'https://github.com/ACGNnsj/venera-unified/releases/download'


def environment_flutter(pubspec):
    section = False
    for line in pubspec.read_text(encoding='utf-8').splitlines():
        if line.startswith('environment:'):
            section = True
            continue
        if not section:
            continue
        if line and not line.startswith((' ', '\t')):
            break
        key, _, value = line.strip().partition(':')
        if key.strip() == 'flutter':
            return value.strip().strip(chr(34) + chr(39))
    raise SystemExit('pubspec.yaml 里没有 environment.flutter')


def app_version(pubspec):
    for line in pubspec.read_text(encoding='utf-8').splitlines():
        if line.startswith('version:'):
            return line.split(':', 1)[1].strip()
    return ''


def load_cache():
    if not SHA_CACHE.exists():
        return {}
    return json.loads(SHA_CACHE.read_text(encoding='utf-8'))


def store_cache(data):
    SHA_CACHE.write_text(json.dumps(dict(sorted(data.items())), indent=2) + '\n', encoding='utf-8')


def fetch_flutter_sha(version):
    archive = 'flutter_linux_%s-stable.tar.xz' % version
    try:
        with urllib.request.urlopen(RELEASES_URL, timeout=60) as response:
            data = json.load(response)
    except (urllib.error.URLError, TimeoutError) as error:
        print('warning: 取 releases_linux.json 失败（%s），改用本地缓存' % error, file=sys.stderr)
        return None
    for release in data.get('releases', []):
        if release.get('version') == version and str(release.get('archive', '')).endswith(archive):
            return release.get('sha256')
    return None


def resolve_flutter_sha(version, offline):
    cache = load_cache()
    if version in cache and offline:
        return cache[version]
    sha = None if offline else fetch_flutter_sha(version)
    if sha is None:
        sha = cache.get(version)
    if sha is None:
        raise SystemExit('拿不到 Flutter %s 的 sha256：联网重试或先写进 flatpak/flutter-sha256.json' % version)
    if cache.get(version) != sha:
        cache[version] = sha
        store_cache(cache)
    return sha


def sha256_of(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def render(template, values):
    text = template.read_text(encoding='utf-8')
    for key, value in values.items():
        token = '@@' + key + '@@'
        if token not in text:
            raise SystemExit('模板里没有占位符 %s' % token)
        text = text.replace(token, value)
    leftover = [word for word in text.split() if word.startswith('@@')]
    if leftover:
        raise SystemExit('模板里还剩未填的占位符：%s' % ', '.join(sorted(set(leftover))))
    return text


def main(argv=None):
    parser = argparse.ArgumentParser(description='渲染 Flatpak manifest')
    parser.add_argument('--tag', help='构建取用的 git 标签与 Release 版本，例如 v1.20.0')
    parser.add_argument('--release-base', help='Release 资产基址，默认按 tag 推导')
    parser.add_argument('--pub-cache', type=pathlib.Path, help='pub-cache 归档')
    parser.add_argument('--engine-artifacts', type=pathlib.Path, help='引擎产物归档')
    parser.add_argument('--cargo-vendor', type=pathlib.Path, help='cargo vendor 归档')
    parser.add_argument('--output', type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument('--offline', action='store_true', help='不联网，只用本地 sha 缓存')
    parser.add_argument('--check', action='store_true', help='只比对 --output 是否与渲染结果一致')
    args = parser.parse_args(argv)

    pubspec = ROOT / 'pubspec.yaml'
    flutter = environment_flutter(pubspec)
    flutter_sha = resolve_flutter_sha(flutter, args.offline)
    tag = args.tag or app_version(pubspec).split('+')[0]
    base = args.release_base or '%s/%s' % (RELEASE_BASE, tag)
    values = {
        'FLUTTER_VERSION': flutter,
        'FLUTTER_SHA256': flutter_sha,
        'RELEASE_BASE': base,
        'SOURCE_TAG': tag,
    }
    for key, path in (('PUB_CACHE', args.pub_cache), ('ENGINE_ARTIFACTS', args.engine_artifacts), ('CARGO_VENDOR', args.cargo_vendor)):
        if path is None:
            raise SystemExit('缺少 --%s 归档；用 --check 以外的用法都要给齐三份归档' % key.lower().replace('_', '-'))
        if not path.is_file():
            raise SystemExit('归档不存在：%s' % path)
        values[key + '_ASSET'] = path.name
        values[key + '_SHA256'] = sha256_of(path)

    rendered = render(TEMPLATE, values)
    if args.check:
        current = args.output.read_text(encoding='utf-8') if args.output.exists() else ''
        if current != rendered:
            print('%s 与模板渲染结果不一致，重跑 flatpak-vendor.yml 生成' % args.output, file=sys.stderr)
            return 1
        print('%s 已是最新' % args.output)
        return 0

    args.output.write_text(rendered, encoding='utf-8')
    print(args.output)
    print('flutter %s sha256=%s' % (flutter, flutter_sha))
    for key in ('PUB_CACHE', 'ENGINE_ARTIFACTS', 'CARGO_VENDOR'):
        print('%s %s %s' % (key.lower(), values[key + '_ASSET'], values[key + '_SHA256']))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

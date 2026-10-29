#!/usr/bin/env python3
"""emulator CI 断言：源码 manifest 保 tool 发现，release 合并 manifest 保单图标。

1. 源码 android/app/src/main/AndroidManifest.xml：MainActivity 必须带
   MAIN/LAUNCHER，否则 flutter tool 报 "package identifier or launch
   activity not found"（tool 不认 activity-alias）。
2. release merged manifest：MainActivity 必须已被
   src/release/AndroidManifest.xml 摘掉 LAUNCHER（否则双图标），且
   LAUNCHER 总数 == 5（五个 Icon* 别名都在）。
"""

import glob
import sys
import xml.etree.ElementTree as ET

ANDROID = '{http://schemas.android.com/apk/res/android}'
LAUNCHER = 'android.intent.category.LAUNCHER'


def fail(msg):
    print(f'ASSERT FAILED: {msg}')
    sys.exit(1)


def has_launcher(activity):
    for f in activity.iter('intent-filter'):
        for c in f.iter('category'):
            if c.get(f'{ANDROID}name') == LAUNCHER:
                return True
    return False


def main_activities(root):
    return [
        a
        for a in root.iter('activity')
        if (a.get(f'{ANDROID}name') or '').endswith('MainActivity')
    ]


# 1. 源码 manifest：tool 发现。
src = ET.parse('android/app/src/main/AndroidManifest.xml').getroot()
mains = main_activities(src)
if not mains:
    fail('源码 manifest 找不到 MainActivity')
if not has_launcher(mains[0]):
    fail('源码 manifest MainActivity 缺 MAIN/LAUNCHER，flutter tool 无法发现')
print('source manifest: MainActivity has LAUNCHER (tool discovery OK)')

# 2. release merged manifest：单图标。
# 注意：flutter gradle 插件把 buildDir 重定向到仓库根 build/ 下，
# merged manifest 不在 android/app/build/ 里。
merged = glob.glob(
    'build/app/intermediates/merged_manifest*/**/AndroidManifest.xml',
    recursive=True,
)
merged = [m for m in merged if '/release/' in m.replace('\\', '/')]
if not merged:
    fail('找不到 release merged manifest（gradle merge 任务没产出？）')
root = ET.parse(merged[0]).getroot()
all_launcher = [
    c
    for c in root.iter('category')
    if c.get(f'{ANDROID}name') == LAUNCHER
]
mains = main_activities(root)
if mains and has_launcher(mains[0]):
    fail('release merged manifest 里 MainActivity 仍有 LAUNCHER：overlay 没摘掉！')
if len(all_launcher) != 5:
    fail(f'LAUNCHER 共 {len(all_launcher)} 个，期望 5（五个 Icon 别名）')
print(f'release merged manifest: MainActivity clean, {len(all_launcher)} alias LAUNCHERs (single-icon OK)')

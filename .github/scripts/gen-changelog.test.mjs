import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildChangelog, notesBody, parseReleases } from './gen-changelog.mjs';

test('keeps only stable tags, newest first by version', () => {
  const releases = parseReleases([
    'v1.18.1\t2026-06-01T10:00:00Z',
    'v1.18.2\t2026-06-05T10:00:00Z\r',
    'v1.18.2-rc.3\t2026-07-01T10:00:00Z',
    'not-a-tag\t2026-07-01T10:00:00Z',
    'v1.19.0\t',
    '',
  ].join('\n'));
  assert.deepEqual(releases, [
    { tag: 'v1.18.2', date: '2026-06-05' },
    { tag: 'v1.18.1', date: '2026-06-01' },
  ]);
});

test('drops the file title but keeps sections and the footer', () => {
  const body = notesBody(
    '## 更新内容\r\n\r\n### 新增\r\n- a\r\n\r\n**完整更新日志**: https://x/compare/a...b\r\n',
  );
  assert.equal(body, '### 新增\n- a\n\n**完整更新日志**: https://x/compare/a...b');
});

test('lists versions under their own headings, with the older-versions link last', () => {
  const out = buildChangelog('zh-CN', [
    { tag: 'v1.18.2', date: '2026-06-05', body: '### 修复\n- b' },
    { tag: 'v1.18.1', date: '2026-06-01', body: '### 新增\n- a' },
  ]);
  const lines = out.split('\n');
  assert.ok(lines[0].startsWith('<!--'));
  assert.equal(lines[2], '# 更新日志');
  const newer = out.indexOf('## v1.18.2 - 2026-06-05');
  const older = out.indexOf('## v1.18.1 - 2026-06-01');
  assert.ok(newer > 0 && older > newer);
  assert.ok(out.trimEnd().endsWith('[GitHub Releases](https://github.com/ACGNnsj/venera-unified/releases)。'));
  assert.ok(out.endsWith('\n') && !out.endsWith('\n\n'));
});

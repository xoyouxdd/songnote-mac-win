import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createStore, createServer } from '../server/server.mjs';
const change = (id, revision, text, extra = {}) => ({ op_id: randomUUID(), note_id: id, base_revision: revision,
  text, color: 'yellow', pinned: false, deleted: false, ...extra });
const input = changes => ({ device_id: 'mac-test-device', changes });

test('Offline writes, retries, conflicts, stale deletes and tombstones preserve content', () => {
  const s = createStore(':memory:');
  const id = randomUUID(), op = change(id, 0, '中文 📝');
  const first = s.sync(input([op]));
  assert.equal(first.notes[0].text, '中文 📝');
  assert.deepEqual(s.sync(input([op])), first);
  const second = s.sync(input([change(id, 1, 'Mac 新版')]));
  const conflict = s.sync({ device_id: 'windows-device', changes: [change(id, 1, 'Windows 离线版')] });
  assert.equal(conflict.results[0].status, 'conflict_copy');
  assert.equal(conflict.notes.length, 2);
  assert.equal(conflict.notes.find(n => n.id === id).text, 'Mac 新版');
  assert.equal(conflict.notes.find(n => n.id !== id).text, 'Windows 离线版');
  const staleDelete = s.sync(input([change(id, 1, '', { deleted: true })]));
  assert.equal(staleDelete.results[0].status, 'delete_conflict');
  assert.equal(staleDelete.notes.find(n => n.id === id).deleted, false);
  const deleted = s.sync(input([change(id, second.results[0].revision, '', { deleted: true })]));
  assert.equal(deleted.notes.find(n => n.id === id).deleted, true);
  const resurrect = s.sync(input([change(id, 2, '离线恢复')]));
  assert.equal(resurrect.results[0].status, 'conflict_copy');
  assert.equal(resurrect.notes.find(n => n.id === id).deleted, true);
  assert.equal(s.sync(input([change(id, 0, '', { deleted: true })])).results[0].status, 'already_deleted');
  s.close();
});

test('Validation is atomic and operation IDs cannot be reused for other content', () => {
  const s = createStore(':memory:');
  const op = change(randomUUID(), 0, '保存');
  assert.throws(() => s.sync(input([op, { ...change(randomUUID(), 0, ''), color: 'invalid' }])), { status: 400 });
  assert.equal(s.snapshot().notes.length, 0);
  s.sync(input([op]));
  assert.throws(() => s.sync(input([{ ...op, text: '不同内容' }])), { status: 409 });
  assert.throws(() => s.sync({ device_id: 'another-device', changes: [op] }), { status: 409 });
  assert.equal(s.snapshot().notes.length, 1);
  s.close();
});

test('Database and idempotent receipts survive restart', () => {
  const dir = mkdtempSync(join(tmpdir(), 'sticky-test-'));
  const path = join(dir, 'notes.sqlite');
  const op = change(randomUUID(), 0, '持久化');
  let s = createStore(path);
  const expected = s.sync(input([op]));
  s.close(); s = createStore(path);
  assert.deepEqual(s.sync(input([op])), expected);
  s.close(); rmSync(dir, { recursive: true });
});

test('HTTP rejects unauthenticated access and accepts authenticated sync', async () => {
  const token = 'test-only-token-'.repeat(4);
  const { server, store } = createServer({ token, database: ':memory:' });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    assert.equal((await fetch(base + '/health')).status, 200);
    assert.equal((await fetch(base + '/v1/snapshot')).status, 401);
    const response = await fetch(base + '/v1/sync', { method: 'POST', headers: { Authorization: `Bearer ${token}` },
      body: JSON.stringify(input([change(randomUUID(), 0, 'HTTP 中文')])) });
    assert.equal(response.status, 200);
    assert.equal((await response.json()).notes[0].text, 'HTTP 中文');
  } finally { await new Promise(resolve => server.close(resolve)); store.close(); }
});

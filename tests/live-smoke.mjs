// Explicit production smoke test; modifies only a note created by this test.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
const config = JSON.parse(readFileSync(new URL('../private/client-config.json', import.meta.url), 'utf8'));
const headers = { Authorization: `Bearer ${config.token}`, 'Content-Type': 'application/json' };
async function sync(device_id, changes) {
  const response = await fetch(config.base_url + '/v1/sync', { method: 'POST', headers, body: JSON.stringify({ device_id, changes }) });
  assert.equal(response.status, 200);
  return response.json();
}
assert.equal((await fetch(config.base_url + '/health')).status, 200);
assert.equal((await fetch(config.base_url + '/v1/snapshot')).status, 401);
const id = randomUUID(), deviceA = randomUUID(), deviceB = randomUUID();
const op = { op_id: randomUUID(), note_id: id, base_revision: 0, text: '联调临时便签（测试后自动删除）', color: 'blue', pinned: true, deleted: false };
let cleanup = [];
try {
  const first = await sync(deviceA, [op]);
  cleanup.push(id);
  assert.equal(first.notes.find(n => n.id === id).text, op.text);
  const retry = await sync(deviceA, [op]);
  assert.deepEqual(retry.results, first.results);
  const a = await sync(deviceA, [{ ...op, op_id: randomUUID(), base_revision: first.results[0].revision, text: 'Mac 的更新', color: 'pink' }]);
  const b = await sync(deviceB, [{ ...op, op_id: randomUUID(), base_revision: first.results[0].revision, text: 'Windows 离线更新' }]);
  assert.equal(b.results[0].status, 'conflict_copy');
  cleanup.push(b.results[0].note_id);
  assert.equal(b.notes.find(n => n.id === id).text, 'Mac 的更新');
  assert.equal(b.notes.find(n => n.id === b.results[0].note_id).text, 'Windows 离线更新');
  const stale = await sync(deviceB, [{ ...op, op_id: randomUUID(), base_revision: first.results[0].revision, deleted: true }]);
  assert.equal(stale.results[0].status, 'delete_conflict');
  assert.equal(stale.notes.find(n => n.id === id).deleted, false);
  console.log('LIVE_SMOKE_OK: HTTPS, authentication, two devices, retry, conflict copy, stale delete');
} finally {
  const state = await sync(deviceA, []);
  const changes = state.notes.filter(n => cleanup.includes(n.id) && !n.deleted).map(n => ({
    op_id: randomUUID(), note_id: n.id, base_revision: n.revision, text: n.text, color: n.color, pinned: n.pinned, deleted: true }));
  if (changes.length) await sync(deviceA, changes);
  console.log('LIVE_TEST_NOTES_SOFT_DELETED');
}

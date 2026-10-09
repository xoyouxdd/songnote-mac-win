import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createStore, createServer, maxFileBytes } from '../server/server.mjs';
const change = (id, revision, text, extra = {}) => ({ op_id: randomUUID(), note_id: id, base_revision: revision,
  text, color: 'yellow', pinned: false, deleted: false, ...extra });
const input = changes => ({ device_id: 'mac-test-device', changes });
const attachment = (data, name = '测试附件.txt') => ({ id: randomUUID(), name, size: data.length,
  sha256: createHash('sha256').update(data).digest('hex') });

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

test('Attachments preserve legacy edits, explicit removal and conflict copies', () => {
  const s = createStore(':memory:');
  try {
    const data = Buffer.from('虚构附件 中文\0binary'), a = attachment(data), id = randomUUID();
    s.putFile(a.sha256, data); s.putFile(a.sha256, data);
    assert.equal(s.db.prepare('SELECT count(*) AS n FROM files').get().n, 1);
    const first = s.sync(input([change(id, 0, '', { attachments: [a] })]));
    assert.deepEqual(first.notes[0].attachments, [a]);
    const stable = change(randomUUID(), 0, '键序重试', { attachments: [a] });
    const receipt = s.sync(input([stable])).results[0];
    const reordered = { sha256: a.sha256, size: a.size, name: a.name, id: a.id };
    assert.deepEqual(s.sync(input([{ ...stable, attachments: [reordered] }])).results[0], receipt);
    const legacy = change(id, 1, '旧端编辑');
    assert.deepEqual(s.sync(input([legacy])).notes[0].attachments, [a]);
    const legacyRevision = s.sync(input([legacy])).results[0].revision;
    const conflicting = s.sync(input([change(id, 1, '离线修改', { attachments: [] })]));
    assert.deepEqual(conflicting.notes.find(n => n.id === id).attachments, [a]);
    assert.deepEqual(conflicting.notes.find(n => n.id === conflicting.results[0].note_id).attachments, []);
    const removed = s.sync(input([change(id, legacyRevision, '移除', { attachments: [] })]));
    assert.deepEqual(removed.notes.find(n => n.id === id).attachments, []);
    assert.deepEqual(Buffer.from(s.getFile(a.sha256)), data);
  } finally { s.close(); }
});

test('Missing files, wrong sizes and unsafe metadata reject the whole note batch', () => {
  const s = createStore(':memory:');
  try {
    const data = Buffer.from('fixture'), a = attachment(data), good = change(randomUUID(), 0, '保持原子');
    assert.throws(() => s.sync(input([good, change(randomUUID(), 0, '', { attachments: [a] })])), { status: 409 });
    assert.equal(s.snapshot().sequence, 0);
    s.putFile(a.sha256, data);
    for (const values of [[{ ...a, size: a.size + 1 }], [{ ...a, name: '../secret' }], [a, a], Array.from({ length: 21 }, () => ({ ...a, id: randomUUID() })), null]) {
      assert.throws(() => s.sync(input([good, change(randomUUID(), 0, '', { attachments: values })])));
      assert.equal(s.snapshot().sequence, 0);
    }
    assert.throws(() => s.putFile(a.sha256, Buffer.from('bad')), { status: 400 });
    assert.throws(() => s.putFile(a.sha256, Buffer.alloc(maxFileBytes + 1)), { status: 413 });
    const op = change(randomUUID(), 0, '', { attachments: [a] }); s.sync(input([op]));
    assert.throws(() => s.sync(input([{ ...op, attachments: [] }])), { status: 409 });
  } finally { s.close(); }
});

test('Legacy database migration keeps stored receipts retryable and backup contains file bytes', () => {
  const dir = mkdtempSync(join(tmpdir(), 'songnote-file-test-')), path = join(dir, 'old.sqlite');
  let s;
  try {
    const op = change(randomUUID(), 0, '旧库内容'), result = { op_id: op.op_id, note_id: op.note_id, revision: 1, status: 'applied' };
    const db = new DatabaseSync(path);
    db.exec(`CREATE TABLE notes(id TEXT PRIMARY KEY,text TEXT NOT NULL,color TEXT NOT NULL,pinned INTEGER NOT NULL,revision INTEGER NOT NULL,updated_at TEXT NOT NULL,deleted INTEGER NOT NULL,conflict_of TEXT);
      CREATE TABLE operations(op_id TEXT PRIMARY KEY,device_id TEXT NOT NULL,request TEXT NOT NULL,result TEXT NOT NULL);
      CREATE TABLE metadata(key TEXT PRIMARY KEY,value INTEGER NOT NULL); INSERT INTO metadata VALUES('sequence',1);`);
    db.prepare('INSERT INTO notes VALUES(?,?,?,?,?,?,?,?)').run(op.note_id, op.text, op.color, 0, 1, 't', 0, null);
    db.prepare('INSERT INTO operations VALUES(?,?,?,?)').run(op.op_id, 'mac-test-device', JSON.stringify([op.note_id, 0, op.text, op.color, false, false]), JSON.stringify(result)); db.close();
    s = createStore(path);
    assert.deepEqual(s.sync(input([op])).results, [result]);
    assert.deepEqual(s.snapshot().notes[0].attachments, []);
    const bytes = Buffer.from('backup fixture'), a = attachment(bytes); s.putFile(a.sha256, bytes);
    s.sync(input([change(op.note_id, 1, '附上文件', { attachments: [a] })]));
    const backup = join(dir, 'backup.sqlite'); s.db.prepare('VACUUM INTO ?').run(backup); s.close(); s = undefined;
    const restored = createStore(backup);
    try { assert.deepEqual(Buffer.from(restored.getFile(a.sha256)), bytes); assert.deepEqual(restored.snapshot().notes[0].attachments, [a]); }
    finally { restored.close(); }
  } finally { s?.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('Authenticated file HTTP supports zero bytes, checksums, retry and download', async () => {
  const token = 't'.repeat(64), { server, store } = createServer({ token, database: ':memory:' });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`, headers = { Authorization: `Bearer ${token}` };
  try {
    assert.ok((await (await fetch(base + '/health')).json()).features.includes('attachments'));
    for (const bytes of [Buffer.alloc(0), Buffer.from('file \0 中文')]) {
      const a = attachment(bytes), url = base + '/v1/files/' + a.sha256;
      for (const method of ['GET', 'HEAD', 'PUT']) assert.equal((await fetch(url, { method })).status, 401);
      assert.equal((await fetch(url, { method: 'HEAD', headers })).status, 404);
      assert.equal((await fetch(url, { method: 'PUT', headers, body: Buffer.from('mismatch') })).status, 400);
      for (let i = 0; i < 2; i++) assert.equal((await fetch(url, { method: 'PUT', headers, body: bytes })).status, 200);
      const head = await fetch(url, { method: 'HEAD', headers }); assert.equal(head.status, 200); assert.equal(Number(head.headers.get('content-length')), bytes.length);
      const downloaded = await fetch(url, { headers }); assert.equal(downloaded.headers.get('content-disposition'), 'attachment');
      assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), bytes);
    }
    const oversized = await fetch(base + '/v1/files/' + 'a'.repeat(64), { method: 'PUT', headers, body: Buffer.alloc(maxFileBytes + 1) });
    assert.equal(oversized.status, 413);
    assert.equal((await fetch(base + '/v1/files/../../private', { headers })).status, 404);
  } finally { await new Promise(resolve => server.close(resolve)); store.close(); }
});

test('Delta sync returns only newer notes plus every note the request touched', () => {
  const s = createStore(':memory:');
  const a = randomUUID(), b = randomUUID();
  s.sync(input([change(a, 0, 'A')])); const second = s.sync(input([change(b, 0, 'B')]));
  const since = second.sequence;
  const idle = s.sync({ ...input([]), since });
  assert.equal(idle.delta, true); assert.deepEqual(idle.notes, []); assert.equal(idle.sequence, since);
  const edit = s.sync({ device_id: 'windows-device', changes: [change(a, 1, 'A2')] });
  const pulled = s.sync({ ...input([]), since });
  assert.deepEqual(pulled.notes.map(n => [n.id, n.text]), [[a, 'A2']]);
  // A conflict copy includes the untouched original so clients can restore the server version.
  const copy = s.sync({ ...input([change(b, 0, 'B offline')]), since: edit.sequence });
  assert.equal(copy.results[0].status, 'conflict_copy');
  assert.deepEqual(new Set(copy.notes.map(n => n.id)), new Set([b, copy.results[0].note_id]));
  // Undo of a synced delete: an edit on the tombstone's revision restores the note.
  const removed = s.sync({ ...input([change(a, edit.results[0].revision, '', { deleted: true })]), since });
  const restored = s.sync({ ...input([change(a, removed.results[0].revision, 'A2')]), since: removed.sequence });
  assert.equal(restored.results[0].status, 'applied'); assert.equal(restored.notes.find(n => n.id === a).deleted, false);
  // Without `since`, or with a sequence the server never reached, the full snapshot is returned.
  assert.equal(s.sync(input([])).delta, undefined); assert.equal(s.sync(input([])).notes.length, 3);
  const ahead = s.sync({ ...input([]), since: 10_000 });
  assert.equal(ahead.delta, undefined); assert.equal(ahead.notes.length, 3);
  s.close();
});

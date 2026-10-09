import http from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { randomUUID, timingSafeEqual, createHash } from 'node:crypto';
import { mkdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const colors = ['yellow', 'green', 'blue', 'pink', 'purple', 'gray'];
const identifier = /^[a-zA-Z0-9_-]{8,80}$/;
const version = readFileSync(new URL('../VERSION', import.meta.url), 'utf8').trim();
export const maxFileBytes = 20 * 1024 * 1024;
const hashPattern = /^[a-f0-9]{64}$/;
const failure = (message, status = 400) => Object.assign(new Error(message), { status });
function validateAttachments(value) {
  if (!Array.isArray(value) || value.length > 20) throw failure('Invalid attachments');
  const ids = new Set();
  for (const a of value) {
    if (!a || typeof a.id !== 'string' || !identifier.test(a.id) || /[\r\n]/.test(a.id) || ids.has(a.id) || typeof a.name !== 'string' ||
        !a.name.length || a.name.length > 255 || /[\\/\x00-\x1f\x7f]/.test(a.name) || ['.', '..'].includes(a.name) ||
        !Number.isSafeInteger(a.size) || a.size < 0 || a.size > maxFileBytes || typeof a.sha256 !== 'string' || a.sha256.length !== 64 || !hashPattern.test(a.sha256))
      throw failure('Invalid attachment');
    ids.add(a.id);
  }
}
export function createStore(path) {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
    CREATE TABLE IF NOT EXISTS notes(id TEXT PRIMARY KEY, text TEXT NOT NULL,
      color TEXT NOT NULL, pinned INTEGER NOT NULL, revision INTEGER NOT NULL,
      updated_at TEXT NOT NULL, deleted INTEGER NOT NULL, conflict_of TEXT);
    CREATE TABLE IF NOT EXISTS operations(op_id TEXT PRIMARY KEY, device_id TEXT NOT NULL,
      request TEXT NOT NULL, result TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
    INSERT OR IGNORE INTO metadata VALUES('sequence',0);
    CREATE TABLE IF NOT EXISTS files(sha256 TEXT PRIMARY KEY, data BLOB NOT NULL);`);
  if (!db.prepare('PRAGMA table_info(notes)').all().some(c => c.name === 'attachments'))
    db.exec("ALTER TABLE notes ADD COLUMN attachments TEXT NOT NULL DEFAULT '[]'");
  const note = row => ({ ...row, attachments: JSON.parse(row.attachments), pinned: !!row.pinned, deleted: !!row.deleted });
  const sequence = () => db.prepare("SELECT value FROM metadata WHERE key='sequence'").get().value;
  const snapshot = () => ({ protocol: 1, sequence: sequence(),
    notes: db.prepare('SELECT * FROM notes ORDER BY revision').all().map(note) });
  // Delta: notes changed after the client's last applied sequence, plus every note this request touched.
  // A client ahead of the server (restored backup) or without `since` receives the full snapshot.
  const changedSince = (since, ids) => {
    const current = sequence();
    if (!Number.isSafeInteger(since) || since < 0 || since > current) return snapshot();
    const rows = new Map(db.prepare('SELECT * FROM notes WHERE revision > ? ORDER BY revision').all(since).map(r => [r.id, r]));
    for (const id of ids) if (!rows.has(id)) { const row = db.prepare('SELECT * FROM notes WHERE id=?').get(id); if (row) rows.set(id, row); }
    return { protocol: 1, sequence: current, delta: true, notes: [...rows.values()].map(note) };
  };
  const sync = input => {
    if (!input || !identifier.test(input.device_id) || !Array.isArray(input.changes) || input.changes.length > 100)
      throw Object.assign(new Error('Invalid device_id or changes'), { status: 400 });
    const seen = new Set();
    for (const op of input.changes) {
      if (!op || !identifier.test(op.op_id) || !identifier.test(op.note_id) || seen.has(op.op_id) ||
        !Number.isSafeInteger(op.base_revision) || op.base_revision < 0 ||
        typeof op.deleted !== 'boolean' || typeof op.text !== 'string' || op.text.length > 100000 ||
        !colors.includes(op.color) || typeof op.pinned !== 'boolean')
        throw Object.assign(new Error('Invalid change'), { status: 400 });
      seen.add(op.op_id);
      const previous = db.prepare('SELECT * FROM operations WHERE op_id=?').get(op.op_id);
      if (previous && (previous.device_id !== input.device_id || previous.request !== canonical(op)))
        throw Object.assign(new Error('op_id reused with different payload'), { status: 409 });
      if (op.attachments !== undefined) {
        validateAttachments(op.attachments);
        for (const a of op.attachments) {
          const stored = db.prepare('SELECT length(data) AS size FROM files WHERE sha256=?').get(a.sha256);
          if (!stored || stored.size !== a.size) throw failure('Attachment must be uploaded first', 409);
        }
      }
    }
    db.exec('BEGIN IMMEDIATE');
    try {
      const results = input.changes.map(op => {
        const previous = db.prepare('SELECT result FROM operations WHERE op_id=?').get(op.op_id);
        if (previous) return JSON.parse(previous.result);
        const current = db.prepare('SELECT * FROM notes WHERE id=?').get(op.note_id);
        let target = op.note_id, conflictOf = current?.conflict_of ?? null;
        let status = 'applied';
        if (current?.deleted && op.deleted) status = 'already_deleted';
        else if ((current?.revision ?? 0) !== op.base_revision) {
          if (op.deleted) status = 'delete_conflict';
          else { target = randomUUID(); conflictOf = op.note_id; status = 'conflict_copy'; }
        }
        let revision = current?.revision ?? 0;
        if (status === 'applied' || status === 'conflict_copy') {
          db.prepare("UPDATE metadata SET value=value+1 WHERE key='sequence'").run();
          revision = db.prepare("SELECT value FROM metadata WHERE key='sequence'").get().value;
          const attachments = op.attachments ?? (current ? JSON.parse(current.attachments) : []);
          db.prepare(`INSERT INTO notes(id,text,color,pinned,revision,updated_at,deleted,conflict_of,attachments) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            text=excluded.text,color=excluded.color,pinned=excluded.pinned,revision=excluded.revision,
            updated_at=excluded.updated_at,deleted=excluded.deleted,conflict_of=excluded.conflict_of,attachments=excluded.attachments`)
            .run(target, op.text, op.color, +op.pinned, revision, new Date().toISOString(), +op.deleted, conflictOf, JSON.stringify(attachments));
        }
        const result = { op_id: op.op_id, note_id: target, revision, status };
        db.prepare('INSERT INTO operations VALUES(?,?,?,?)').run(op.op_id, input.device_id, canonical(op), JSON.stringify(result));
        return result;
      });
      const touched = new Set([...input.changes.map(op => op.note_id), ...results.map(r => r.note_id)]);
      const response = { ...(input.since === undefined ? snapshot() : changedSince(input.since, touched)), results };
      db.exec('COMMIT');
      return response;
    } catch (error) { db.exec('ROLLBACK'); throw error; }
  };
  const fileSize = hash => db.prepare('SELECT length(data) AS size FROM files WHERE sha256=?').get(hash)?.size;
  const putFile = (hash, data) => {
    if (!hashPattern.test(hash) || data.length > maxFileBytes) throw failure('Invalid file', 413);
    if (createHash('sha256').update(data).digest('hex') !== hash) throw failure('File checksum mismatch');
    db.exec('BEGIN IMMEDIATE');
    try {
      if (fileSize(hash) === undefined) {
        const total = db.prepare('SELECT coalesce(sum(length(data)),0) AS size FROM files').get().size;
        if (total + data.length > 1024 * 1024 * 1024) throw failure('File storage full', 507);
        db.prepare('INSERT INTO files VALUES(?,?)').run(hash, data);
      }
      db.exec('COMMIT');
    } catch (error) { db.exec('ROLLBACK'); throw error; }
  };
  return { db, sync, snapshot, fileSize, putFile,
    getFile: hash => db.prepare('SELECT data FROM files WHERE sha256=?').get(hash)?.data,
    close: () => db.close() };
}
function canonical(op) {
  const fields = [op.note_id, op.base_revision, op.text, op.color, op.pinned, op.deleted];
  // Preserve receipts created before the optional attachment extension.
  if (op.attachments !== undefined) fields.push(Array.isArray(op.attachments)
    ? op.attachments.map(a => a && [a.id, a.name, a.size, a.sha256]) : op.attachments);
  return JSON.stringify(fields);
}

export function createServer({ token, database }) {
  if (typeof token !== 'string' || token.length < 32) throw new Error('A private token is required');
  const store = createStore(database);
  const expected = Buffer.from(`Bearer ${token}`);
  let uploading = 0;
  const server = http.createServer(async (req, res) => {
    const send = (status, payload) => {
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff' });
      res.end(JSON.stringify(payload));
    };
    if (req.url === '/health' && req.method === 'GET') return send(200, { ok: true, version, protocol: 1, features: ['attachments', 'delta'], max_file_bytes: maxFileBytes });
    const actual = Buffer.from(req.headers.authorization ?? '');
    if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) return send(401, { error: 'Unauthorized' });
    if (req.url === '/v1/snapshot' && req.method === 'GET') return send(200, store.snapshot());
    const fileMatch = /^\/v1\/files\/([a-f0-9]{64})$/.exec(req.url);
    if (fileMatch && ['GET', 'HEAD', 'PUT'].includes(req.method)) {
      try {
        const hash = fileMatch[1];
        if (req.method === 'PUT') {
          if (uploading >= 2) return send(429, { error: 'Too many file uploads' });
          if (Number(req.headers['content-length']) > maxFileBytes) return send(413, { error: 'File too large' });
          uploading++;
          try {
          let size = 0; const chunks = [];
          for await (const chunk of req) {
            size += chunk.length;
            if (size > maxFileBytes) { send(413, { error: 'File too large' }); req.resume(); return; }
            chunks.push(chunk);
          }
          store.putFile(hash, Buffer.concat(chunks));
          return send(200, { sha256: hash, size });
          } finally { uploading--; }
        }
        const size = store.fileSize(hash);
        if (size === undefined) return send(404, { error: 'File not found' });
        res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': size,
          'Content-Disposition': 'attachment', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
        return res.end(req.method === 'HEAD' ? undefined : store.getFile(hash));
      } catch (error) { return send(error.status ?? 500, { error: error.status ? error.message : 'File storage error' }); }
    }
    if (req.url !== '/v1/sync' || req.method !== 'POST') return send(404, { error: 'Not found' });
    try {
      let size = 0, chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 2 * 1024 * 1024) { send(413, { error: 'Request too large' }); req.resume(); return; }
        chunks.push(chunk);
      }
      const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      send(200, store.sync(input));
    } catch (error) {
      send(error.status ?? (error instanceof SyntaxError ? 400 : 500), { error: error.status || error instanceof SyntaxError ? error.message : 'Storage error' });
      if (!error.status && !(error instanceof SyntaxError)) console.error('Sync storage failure', error.code ?? error.name);
    }
  });
  server.requestTimeout = 120000;
  server.headersTimeout = 10000;
  return { server, store };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const config = JSON.parse(readFileSync(process.env.STICKY_CONFIG ?? resolve(dirname(fileURLToPath(import.meta.url)), 'config.json'), 'utf8'));
  const { server, store } = createServer({ token: config.token, database: config.database });
  server.listen(config.port ?? 18084, config.host ?? '127.0.0.1', () => console.log('Sticky Notes server ready'));
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => { store.close(); process.exit(0); }));
}

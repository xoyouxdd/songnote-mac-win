import http from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { mkdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const colors = ['yellow', 'green', 'blue', 'pink', 'purple', 'gray'];
const identifier = /^[a-zA-Z0-9_-]{8,80}$/;
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
    INSERT OR IGNORE INTO metadata VALUES('sequence',0);`);
  const note = row => ({ ...row, pinned: !!row.pinned, deleted: !!row.deleted });
  const snapshot = () => ({ protocol: 1, sequence: db.prepare("SELECT value FROM metadata WHERE key='sequence'").get().value,
    notes: db.prepare('SELECT * FROM notes ORDER BY revision').all().map(note) });
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
          db.prepare(`INSERT INTO notes VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            text=excluded.text,color=excluded.color,pinned=excluded.pinned,revision=excluded.revision,
            updated_at=excluded.updated_at,deleted=excluded.deleted,conflict_of=excluded.conflict_of`)
            .run(target, op.text, op.color, +op.pinned, revision, new Date().toISOString(), +op.deleted, conflictOf);
        }
        const result = { op_id: op.op_id, note_id: target, revision, status };
        db.prepare('INSERT INTO operations VALUES(?,?,?,?)').run(op.op_id, input.device_id, canonical(op), JSON.stringify(result));
        return result;
      });
      const response = { ...snapshot(), results };
      db.exec('COMMIT');
      return response;
    } catch (error) { db.exec('ROLLBACK'); throw error; }
  };
  return { db, sync, snapshot, close: () => db.close() };
}
function canonical(op) {
  return JSON.stringify([op.note_id, op.base_revision, op.text, op.color, op.pinned, op.deleted]);
}

export function createServer({ token, database }) {
  if (typeof token !== 'string' || token.length < 32) throw new Error('A private token is required');
  const store = createStore(database);
  const expected = Buffer.from(`Bearer ${token}`);
  const server = http.createServer(async (req, res) => {
    const send = (status, payload) => {
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff' });
      res.end(JSON.stringify(payload));
    };
    if (req.url === '/health' && req.method === 'GET') return send(200, { ok: true, protocol: 1 });
    const actual = Buffer.from(req.headers.authorization ?? '');
    if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) return send(401, { error: 'Unauthorized' });
    if (req.url === '/v1/snapshot' && req.method === 'GET') return send(200, store.snapshot());
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
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  return { server, store };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const config = JSON.parse(readFileSync(process.env.STICKY_CONFIG ?? resolve(dirname(fileURLToPath(import.meta.url)), 'config.json'), 'utf8'));
  const { server, store } = createServer({ token: config.token, database: config.database });
  server.listen(config.port ?? 18084, config.host ?? '127.0.0.1', () => console.log('Sticky Notes server ready'));
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => { store.close(); process.exit(0); }));
}

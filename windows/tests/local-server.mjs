// Test-only in-memory service. Never reads server/config.json or production data.
import { createServer } from '../../server/server.mjs';
const { server, store } = createServer({ token: 't'.repeat(64), database: ':memory:' });
server.listen(0, '127.0.0.1', () => console.log(`TEST_SERVER_PORT:${server.address().port}`));
let stopping = false;
function stop() {
  if (stopping) return;
  stopping = true;
  server.close(() => { store.close(); process.exit(0); });
}
process.stdin.setEncoding('utf8');
process.stdin.on('data', text => { if (text.includes('stop')) stop(); });
process.on('SIGINT', stop);
process.on('SIGTERM', stop);

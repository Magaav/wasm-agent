import {DatabaseSync} from 'node:sqlite';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const [W, STORE] = process.argv.slice(2);
const {create} = await import(pathToFileURL(path.join(W, 'scripts/wave-lifecycle.mjs')).href);
const idx = () => { const db = new DatabaseSync(path.join(STORE, 'waves.sqlite'), {readOnly: true}); const r = db.prepare("SELECT name FROM sqlite_master WHERE type='index'").all().map(x => x.name); db.close(); return r; };
const manifest = {id: 'probe', owner: 'probe', repo: 'C:/Users/Victor/orca/projects/wasm-agent', executor_cwd: 'C:/Users/Victor/.wasm-agent/waves/wave-evolution-1', bootstrap: true,
  steps: ['land', 'deploy', 'retire'].map(n => ({name: n, argv: [process.execPath, '-e', '0'], post: {argv: [process.execPath, '-e', '0']}})),
  verifiers: Object.fromEntries(['operations', 'claims', 'runtime', 'registries', 'deliveries', 'owners'].map(k => [k, {argv: [process.execPath, '-e', '0']}]))};
console.log('indexes BEFORE any wave command:', JSON.stringify(idx()));
try { const r = create(STORE, manifest); console.log('create() returned', JSON.stringify({id: r.id, previous: r.previous})); }
catch (e) { console.log('create() threw:', e.message.slice(0, 160)); }
console.log('indexes AFTER the first open()-using command:', JSON.stringify(idx()));

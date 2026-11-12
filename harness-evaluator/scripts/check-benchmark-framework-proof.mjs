// Retained receipt check only: never replays a framework or provider request.
import fs from 'node:fs';import path from 'node:path';import assert from 'node:assert/strict';
const root=process.argv[2];assert(root&&path.isAbsolute(root));const r=JSON.parse(fs.readFileSync(path.join(root,'receipt.json')));
assert(r.ok&&r.pi_sdk_covered===true&&r.paid_solver_calls===0&&r.results.length===4);
assert.deepEqual(new Set(r.results.map(x=>x.arm)),new Set(['pi','wasm-current','node-v1','rust-v2']));
assert(r.results.every(x=>x.exit===0&&x.rounds===2&&x.real_tool_output_replayed));
console.log(JSON.stringify({ok:true,frameworks:4,paid_solver_calls:0}));

#!/usr/bin/env node
// Slice c78ab731's bounded gate-home block (the exact bytes) out of verify/b1-test.sh at its own
// marker line, so verify/gate-home-liveness.sh runs the delivered code rather than a paraphrase.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url));
const [src, out] = process.argv.slice(2);
const text = fs.readFileSync(path.join(here, src), 'utf8');
const lines = text.split('\n');
const marker = lines.findIndex(l => l.startsWith('# ---- end of the bounded gate-home block'));
if (marker < 1) throw Error('marker not found');
const slice = lines.slice(0, marker).join('\n');
fs.writeFileSync(path.join(here, out), `${slice}\n`);
console.log(`sliced ${marker} lines (${Buffer.byteLength(slice)} bytes) into ${out}`);
console.log(`ends with the EXIT trap: ${slice.trimEnd().endsWith('trap gate_home_release EXIT')}`);

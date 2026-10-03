// Private fixture built by the independent real-heartbeat reproduction first.
// Usage: node scripts/test-wave-owner-refusal.mjs PRIVATE_CONFIG
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {observe, resolve} from './wave-activity.mjs';
import {findResolution, sourceOfConfig, activityStore} from './lib/wave-activity.mjs';
const config = process.argv[2];
assert.ok(config, 'private config required');
const source = sourceOfConfig(JSON.parse(fs.readFileSync(config, 'utf8')));
const file = activityStore(source).resolutions;
const before = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
assert.throws(() => resolve(config, 'working-child', 'mere prose', {run:'held-run'}), /exact_owner_settlement_and_drain_unavailable/);
assert.equal(fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null, before);
assert.equal(findResolution([{session:'x',claim:'x'}], {session:'x',claim:'x'}, {corroborated:false}), null);
assert.equal(findResolution([{session:'x',claim:'x'}], {session:'x',claim:'x'}, {corroborated:null}), null);
const result = observe(config);
assert.notEqual(result.activity, 'off');
assert.ok(result.activity_claims.every(x => x.resolvable === false));
console.log('owner refusal: 6 assertions passed; no native or full gate coverage');

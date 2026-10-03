import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
const repo=fs.readFileSync('reviews/local-dd79/source-path.txt','utf8');
const {verifyFocused}=await import(pathToFileURL(path.join(repo,'scripts/producer-admission.mjs')));
const {terminal}=await import(pathToFileURL(path.join(repo,'scripts/lib/delivery-producer-proof.mjs')));
const receipt=JSON.parse(fs.readFileSync(path.join(repo,'.git/wa-producer-check.json')));
console.log(JSON.stringify({actual:verifyFocused(repo,receipt,receipt.head),runner_identity_present:'runner_identity' in receipt,terminalIndentedSkip:terminal('test-delivery-admission.mjs','  SKIP coverage\ndelivery admission ok (58 checks)')}));
assert.equal(terminal('test-delivery-admission.mjs','  SKIP coverage\ndelivery admission ok (58 checks)'),true);
// Do not forge an accepted receipt or mutate authentic proof; isolated parser reproduction only.

#!/usr/bin/env node
// Spell postcondition: re-read the bounded inventory and require its recorded identity.
import assert from 'node:assert/strict';
import {artifacts} from './artifacts.mjs';
try {
  const [root,prefix,snapshot,matched]=process.argv.slice(2);
  const page=artifacts({root,prefix,snapshot,maxBytes:24000});
  assert(page.complete,'inventory needs pages; use the CLI instead of this bounded spell');
  assert.equal(page.matched_runs,Number(matched));
  console.log(JSON.stringify({ok:true,complete:true,recursive:false,snapshot:page.snapshot,matched_runs:page.matched_runs}));
} catch(error) {console.log(JSON.stringify({ok:false,error:error.message}));process.exitCode=1;}

#!/usr/bin/env node
// Reads an existing metadata export only: no database, runtime, provider, or network access.
const fs = require('node:fs');
const {audit} = require('./lib/token-audit.cjs');
if (process.argv.length !== 3 || process.argv[2] === '--help') {
  console.log('Usage: node scripts/audit-tokens.cjs <complete-telemetry-export.json>\nWrites aggregate JSON to stdout. No prompt content is printed.');
  process.exit(process.argv[2] === '--help' ? 0 : 2);
}
try {
  let text;
  try {
    const fd=fs.openSync(process.argv[2],'r');
    try {
      const size=fs.fstatSync(fd).size;
      if(size>64*1024*1024) throw Error('export_too_large');
      text=fs.readFileSync(fd,'utf8');
    } finally {fs.closeSync(fd);}
  } catch {throw Error('export_read_failed_or_exceeds_64_MiB');}
  let input;
  try {input=JSON.parse(text);} catch {throw Error('invalid_export_json');}
  console.log(JSON.stringify(audit(input),null,2));
} catch (error) {
  console.error('token audit failed: '+error.message);
  process.exitCode=1;
}

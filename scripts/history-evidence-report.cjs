#!/usr/bin/env node
// Publish only aggregate measurements, never transcript bodies or private database paths.
const fs=require('node:fs'),crypto=require('node:crypto');
const [receiptFile,out]=process.argv.slice(2);if(!receiptFile||!out)throw Error('receipt and output required');
const raw=fs.readFileSync(receiptFile),r=JSON.parse(raw);if(!r.ok||r.skipped!==0)throw Error('nonpassing receipt');
const report={schema:'wasm-agent.history-search-evaluation/v1',review:'self-review',receipt_sha256:crypto.createHash('sha256').update(raw).digest('hex'),source:r.source,checks:r.checks,skipped:r.skipped,paid_calls:0,gate_verified:false,release_verified:false,runs:r.runs,
 conclusions:['Source-linked dialogue retrieval reduces log flooding on the observed archive.','Known-source access, Unicode, corrections and authorization were tested deterministically.','No paid-model task correctness, token cost, OS-cache-cold latency or instant response guarantee is established.','Synthetic dialogue-only efficiency query was slower than the old unrestricted query; session diversity and encoded previews have overhead.']};
fs.writeFileSync(out,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({ok:true,checks:r.checks,private_content_exported:false}));

#!/usr/bin/env node
// Read-only report discovery. Never descend into run worktrees or log archives.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

const reports=['manifest.json','report.json','summary.json','three-lane-summary.json'];
export function artifacts({root,prefix,maxBytes=8192,offset=0,snapshot}) {
  if (!root || !prefix || /[\\/\0]/.test(prefix)) throw Error('root and a nonempty immediate-directory prefix are required');
  if (!Number.isSafeInteger(maxBytes) || maxBytes<512 || maxBytes>24000) throw Error('max-bytes must be512..24000');
  if (!Number.isSafeInteger(offset) || offset<0) throw Error('offset must be a nonnegative integer');
  root=fs.realpathSync(root);
  const entries=[],dir=fs.opendirSync(root);
  let scanned=0,inspected=0;
  try {
    for(let entry;(entry=dir.readSync());) {
      if (++scanned>4096) throw Error('more than4096 immediate entries; narrow the artifact root');
      if (!entry.name.startsWith(prefix)) continue;
      if (entry.isSymbolicLink()) throw Error('matching symbolic-link run refused: '+entry.name);
      if (!entry.isDirectory()) continue;
      const found=[];
      for(const name of reports) {
        inspected++;
        const file=path.join(root,entry.name,name);
        let stat;
        try {stat=fs.lstatSync(file);} catch(error) {if(error.code==='ENOENT') continue;throw error;}
        if (!stat.isFile() || stat.isSymbolicLink()) throw Error('report is not a regular file: '+entry.name+'/'+name);
        found.push({path:entry.name+'/'+name,bytes:stat.size,modified_ms:stat.mtimeMs});
      }
      entries.push({directory:entry.name,artifacts:found,report_present:found.some(f=>f.path.endsWith('/report.json'))});
    }
  } finally {dir.closeSync();}
  entries.sort((a,b)=>a.directory<b.directory ? -1 : a.directory>b.directory ? 1 : 0);
  const digest=crypto.createHash('sha256').update(JSON.stringify({root,prefix,entries})).digest('hex');
  if (snapshot && snapshot!==digest) throw Error('report inventory changed; start a fresh discovery');
  if (offset && !snapshot) throw Error('continuation requires snapshot');
  if (offset>entries.length) throw Error('offset exceeds matched runs');
  const runs=[];
  const page=()=>({ok:true,root,prefix,recursive:false,scanned_entries:scanned,inspected_report_paths:inspected,
    matched_runs:entries.length,offset,returned:runs.length,runs,snapshot:digest,
    complete:offset+runs.length===entries.length,next_offset:offset+runs.length<entries.length ? offset+runs.length : null,
    omitted_after:entries.length-offset-runs.length});
  const bytes=()=>Buffer.byteLength(JSON.stringify(page())+'\n');
  if(bytes()>maxBytes) throw Error('budget too small for report metadata');
  for(const run of entries.slice(offset)) {runs.push(run);if(bytes()>maxBytes){runs.pop();break;}}
  if(!runs.length && offset<entries.length) throw Error('budget too small for one run; narrow prefix or raise max-bytes');
  return page();
}

function main() {
  const names={'--root':'root','--prefix':'prefix','--max-bytes':'maxBytes','--offset':'offset','--snapshot':'snapshot'};
  const options={},args=process.argv.slice(2);
  for(let i=0;i<args.length;i+=2) {
    const name=names[args[i]],value=args[i+1];
    if(!name || value===undefined || Object.hasOwn(options,name)) throw Error('usage: --root ROOT --prefix PREFIX [--max-bytes N] [--offset N --snapshot SHA]');
    options[name]=['offset','maxBytes'].includes(name) ? Number(value) : value;
  }
  console.log(JSON.stringify(artifacts(options)));
}
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {main();} catch(error) {console.log(JSON.stringify({ok:false,error:error.message}));process.exitCode=1;}
}

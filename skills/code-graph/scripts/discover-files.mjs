#!/usr/bin/env node
// Read-only fallback discovery: relative paths, explicit scope and complete pages.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export function discoverFiles({root, scopes, match, offset=0, maxBytes=8192, snapshot}) {
  if (!root || !Array.isArray(scopes) || !scopes.length || scopes.length>8)
    throw Error('root and 1-8 explicit relative scopes are required');
  if (!Number.isSafeInteger(offset) || offset<0) throw Error('offset must be a nonnegative integer');
  if (!Number.isSafeInteger(maxBytes) || maxBytes<512 || maxBytes>24000)
    throw Error('max-bytes must be an integer from512 to24000');
  root=fs.realpathSync(root);
  if (!fs.statSync(root).isDirectory()) throw Error('root must be a directory');
  const normalized=scopes.map(scope=>{
    if (!scope || path.isAbsolute(scope) || /^[A-Za-z]:/.test(scope))
      throw Error('scope must be relative to root');
    const absolute=fs.realpathSync(path.resolve(root,scope));
    const relative=path.relative(root,absolute);
    if (relative==='..' || relative.startsWith('..'+path.sep) || path.isAbsolute(relative))
      throw Error('scope escapes root');
    return relative.replaceAll('\\','/') || '.';
  });
  const matcher=match ? new RegExp(match,'i') : null;
  const result=spawnSync('rg',['--files','--null','--color','never','--',...normalized],
    {cwd:root,encoding:'utf8',windowsHide:true,timeout:30000,maxBuffer:16*1024*1024});
  if (result.error || ![0,1].includes(result.status) || result.stderr.trim())
    throw Error('rg discovery failed: '+(result.error?.message || result.stderr || result.status));
  const inventory=[...new Set(result.stdout.split('\0').filter(Boolean)
    .map(file=>(process.platform==='win32' ? file.replaceAll('\\','/') : file).replace(/^\.\//,'')))].sort();
  const candidates=inventory.filter(file=>!matcher || matcher.test(file));
  const digest=crypto.createHash('sha256').update(JSON.stringify({root,scopes:normalized,match:match||'',paths:candidates})).digest('hex');
  if (snapshot && snapshot!==digest) throw Error('inventory changed; start a fresh discovery');
  if (offset>0 && !snapshot) throw Error('continuation requires snapshot from the previous page');
  if (offset>candidates.length) throw Error('offset exceeds matched inventory');
  const paths=[];
  const page=()=>({ok:true,root,scopes:normalized,match:match||null,scanned:inventory.length,
    matched:candidates.length,offset,returned:paths.length,paths,snapshot:digest,
    complete:offset+paths.length===candidates.length,
    next_offset:offset+paths.length<candidates.length ? offset+paths.length : null,
    omitted_after:candidates.length-offset-paths.length});
  const bytes=()=>Buffer.byteLength(JSON.stringify(page())+'\n');
  if (bytes()>maxBytes) throw Error('budget too small for discovery metadata');
  for (const file of candidates.slice(offset)) {
    paths.push(file);
    if (bytes()>maxBytes) {paths.pop();break;}
  }
  if (!paths.length && offset<candidates.length) throw Error('budget too small for one path; narrow scope or raise max-bytes');
  return page();
}

function main() {
  const options={scopes:[]};
  const names={'--root':'root','--scope':'scope','--match':'match','--offset':'offset','--max-bytes':'maxBytes','--snapshot':'snapshot'};
  const args=process.argv.slice(2);
  for (let i=0;i<args.length;i+=2) {
    const name=names[args[i]],value=args[i+1];
    if (!name || value===undefined) throw Error('usage: --root ROOT --scope RELATIVE [--scope RELATIVE] [--match REGEX] [--offset N --snapshot SHA] [--max-bytes N]');
    if (name==='scope') options.scopes.push(value);
    else {if (Object.hasOwn(options,name)) throw Error('duplicate option: '+args[i]);options[name]=['offset','maxBytes'].includes(name)?Number(value):value;}
  }
  console.log(JSON.stringify(discoverFiles(options)));
}
if (process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {main();} catch(error) {console.log(JSON.stringify({ok:false,error:error.message}));process.exitCode=1;}
}

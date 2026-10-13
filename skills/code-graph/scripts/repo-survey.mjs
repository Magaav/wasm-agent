#!/usr/bin/env node
// Read-only metadata pages over a retained repository survey. Never fetch or execute repository code.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

const MAX_FILE_BYTES=32*1024*1024,MAX_CAPTURE_BYTES=64*1024*1024;
const REPO=/^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/;
const hex=(bytes)=>crypto.createHash('sha256').update(bytes).digest('hex');
const within=(root,target)=>{const rel=path.relative(root,target);return rel!== '..'&&!rel.startsWith('..'+path.sep)&&!path.isAbsolute(rel);};
const preview=(text,limit)=>{let out='',bytes=0;for(const c of text){const n=Buffer.byteLength(c);if(bytes+n>limit)break;out+=c;bytes+=n;}return out;};

export function surveyView({cache,offset=0,maxBytes=8192,snapshot}={}) {
  if(typeof cache!=='string'||!path.isAbsolute(cache))throw Error('cache must be an absolute directory');
  if(!Number.isSafeInteger(offset)||offset<0)throw Error('offset must be a nonnegative integer');
  if(!Number.isSafeInteger(maxBytes)||maxBytes<2048||maxBytes>51200)throw Error('max-bytes must be an integer from2048 to51200');
  if(snapshot!==undefined&&(typeof snapshot!=='string'||!/^[a-f0-9]{64}$/.test(snapshot)))throw Error('invalid snapshot');
  if(offset>0&&!snapshot)throw Error('continuation requires snapshot');
  cache=fs.realpathSync(cache);if(!fs.statSync(cache).isDirectory())throw Error('cache must be a directory');
  const captured=[],decoder=new TextDecoder('utf-8',{fatal:true});let totalBytes=0;
  const read=(relative)=>{
    const filename=fs.realpathSync(path.resolve(cache,relative));
    if(!within(cache,filename))throw Error('evidence path escapes cache');
    const info=fs.statSync(filename);if(!info.isFile()||info.size>MAX_FILE_BYTES)throw Error('invalid or oversized evidence file');
    const bytes=fs.readFileSync(filename);totalBytes+=bytes.length;if(totalBytes>MAX_CAPTURE_BYTES)throw Error('survey capture exceeds byte bound');
    captured.push({relative,filename,bytes});return decoder.decode(bytes);
  };
  const manifest=JSON.parse(read('receipt.json'));
  if(!Array.isArray(manifest.results)||manifest.results.length>1000)throw Error('invalid survey manifest');
  const rows=[],seen=new Set(),directories=new Set();
  for(const item of manifest.results){
    if(!item||typeof item.repo!=='string'||!REPO.test(item.repo)||seen.has(item.repo.toLowerCase())||typeof item.ok!=='boolean')throw Error('invalid or duplicate repository record');
    seen.add(item.repo.toLowerCase());const directory=item.repo.replace('/','--');
    if(directories.has(directory.toLowerCase()))throw Error('ambiguous evidence directory');directories.add(directory.toLowerCase());
    if(!item.ok){
      if(typeof item.error!=='string')throw Error('failed repository has no error');
      const error=preview(item.error,512);rows.push({repo:item.repo,ok:false,error,error_truncated:error!==item.error,evidence_dir:directory});continue;
    }
    const metadata=JSON.parse(read(directory+'/metadata.json'));
    const commit=JSON.parse(read(directory+'/commit.json'));
    const tree=JSON.parse(read(directory+'/tree.json'));
    if(!/^[a-f0-9]{40,64}$/.test(item.commit||'')||commit.sha!==item.commit||typeof metadata.archived!=='boolean'||typeof tree.truncated!=='boolean'||!Array.isArray(tree.tree))throw Error('cached repository evidence mismatch');
    const url=metadata.html_url;
    if(typeof url!=='string'||!/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(url))throw Error('invalid cached repository URL');
    const language=metadata.language??null,license=metadata.license?.spdx_id??null,date=commit.commit?.committer?.date??null;
    for(const value of [language,license,date])if(value!==null&&(typeof value!=='string'||Buffer.byteLength(value)>128))throw Error('invalid cached metadata field');
    let readme=false;
    if(item.readme_bytes!==undefined){
      if(!Number.isSafeInteger(item.readme_bytes)||item.readme_bytes<0)throw Error('invalid README byte count');
      const text=read(directory+'/README.md');if(Buffer.byteLength(text)!==item.readme_bytes)throw Error('cached README byte count mismatch');readme=true;
    }
    rows.push({repo:item.repo,ok:true,url,commit:item.commit,commit_at:date,language,license,archived:metadata.archived,tree_truncated:tree.truncated,readme,evidence_dir:directory});
  }
  const digest=crypto.createHash('sha256');digest.update(cache+'\0');
  for(const entry of captured){digest.update(entry.relative+'\0'+entry.bytes.length+'\0');digest.update(entry.bytes);}
  const version=digest.digest('hex');if(snapshot&&snapshot!==version)throw Error('survey snapshot changed; start a fresh view');
  if(offset>rows.length)throw Error('offset exceeds survey');
  // Refuse a capture that changed while it was being read; never bless mixed evidence.
  for(const entry of captured){const filename=fs.realpathSync(path.resolve(cache,entry.relative));if(filename!==entry.filename||hex(fs.readFileSync(filename))!==hex(entry.bytes))throw Error('survey evidence changed during capture');}
  const results=[],failedTotal=rows.filter(r=>!r.ok).length;
  const page=()=>({ok:true,collection_ok:failedTotal===0,cache_root:cache,manifest:'receipt.json',snapshot:version,
    total:rows.length,failed_total:failedTotal,offset,returned:results.length,results,
    complete:offset+results.length===rows.length,next_offset:offset+results.length<rows.length?offset+results.length:null,
    omitted_after:rows.length-offset-results.length,
    evidence_files:['metadata.json','commit.json','tree.json','README.md'],
    omitted_fields:['readme_excerpts','candidate_files','description','stars'],
    note:'Metadata view only. Read retained files under evidence_dir; inspect collection failures and tree_truncated. No source text was discarded.'});
  const bytes=()=>Buffer.byteLength(JSON.stringify(page())+'\n');
  if(bytes()>maxBytes)throw Error('budget too small for survey metadata');
  for(const row of rows.slice(offset)){results.push(row);if(bytes()>maxBytes){results.pop();break;}}
  if(!results.length&&offset<rows.length)throw Error('budget too small for one repository');
  return page();
}

function main(){
  const names={'--cache':'cache','--offset':'offset','--max-bytes':'maxBytes','--snapshot':'snapshot'},options={},args=process.argv.slice(2);
  for(let i=0;i<args.length;i+=2){const name=names[args[i]],value=args[i+1];if(!name||value===undefined||Object.hasOwn(options,name))throw Error('usage: --cache ABSOLUTE [--max-bytes N] [--offset N --snapshot SHA]');options[name]=['offset','maxBytes'].includes(name)?Number(value):value;}
  const page=surveyView(options);console.log(JSON.stringify(page));if(!page.collection_ok)process.exitCode=1;
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  try{main();}catch(error){console.log(JSON.stringify({ok:false,error:preview(String(error.message||error),512)}));process.exitCode=1;}
}

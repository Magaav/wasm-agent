// Model-free build-time provisioning. Runtime needs neither Node nor npm/network.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import assert from 'node:assert/strict';
import {fileURLToPath,pathToFileURL} from 'node:url';
const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const [output,cache]=process.argv.slice(2);
assert(output&&path.isAbsolute(output),'fresh absolute output required');
assert(!fs.existsSync(output),'asset generation already exists');fs.mkdirSync(output,{recursive:true});
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const pins=[
 {name:'@earendil-works/pi-codemode',version:'1.2.0',cache:'_earendil-works_pi-codemode',url:'https://registry.npmjs.org/@earendil-works/pi-codemode/-/pi-codemode-1.2.0.tgz',integrity:'sha512-UZF7IN0IIrf3bop2wTxrwoAakGctH6d3zdPwhPN+QHMECfoI5E6B6l6I17YGFZPj8cmGex6xX7mLCNJXRf7wsw=='},
 {name:'quickjs-wasi',version:'3.6.2',cache:'quickjs-wasi',url:'https://registry.npmjs.org/quickjs-wasi/-/quickjs-wasi-3.6.2.tgz',integrity:'sha512-FCqGtGOrMgzUiIrMNMA2YnsOxCNwo31dzqXvclXUC6xeT35NJLKXQJsvbeCTjvoFAwZgEAPg8U6+KAPDGXn8Mg=='}
];
// No tar executable/dependencies. Only ordinary package files are materialized;
// no links, devices, traversal, PAX overrides or duplicate paths are accepted.
function unpack(compressed,root){const tar=zlib.gunzipSync(compressed,{maxOutputLength:16*1024*1024});const seen=new Set();
 for(let at=0;at+512<=tar.length;){const h=tar.subarray(at,at+512);if(h.every(b=>b===0))break;
  const text=(start,n)=>h.subarray(start,start+n).toString().split('\0')[0];
  const name=[text(345,155),text(0,100)].filter(Boolean).join('/');const size=parseInt(text(124,12).trim(),8)||0;const type=text(156,1);at+=512;
  assert(Number.isSafeInteger(size)&&size>=0&&at+size<=tar.length,'invalid tar length');
  assert(name.startsWith('package/')&&!name.includes('\\')&&!name.split('/').some(p=>p==='..'||p==='.'),'unsafe tar path');
  if(type==='5'){at+=Math.ceil(size/512)*512;continue;}assert(type===''||type==='0','nonregular package member');assert(!seen.has(name),'duplicate tar member');seen.add(name);
  const target=path.join(root,name.slice(8));fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,tar.subarray(at,at+size));at+=Math.ceil(size/512)*512;
 }
}
const records=[];
for(const pin of pins){let bytes;
 if(cache){const dir=path.join(cache,pin.cache);const files=fs.readdirSync(dir).filter(n=>n.endsWith('.tgz'));assert(files.length===1,'exactly one cached original tarball required');bytes=fs.readFileSync(path.join(dir,files[0]));}
 else {const response=await fetch(pin.url);assert(response.ok,'package download failed: '+response.status);bytes=Buffer.from(await response.arrayBuffer());}
 assert('sha512-'+crypto.createHash('sha512').update(bytes).digest('base64')===pin.integrity,'npm integrity mismatch');fs.writeFileSync(path.join(output,pin.cache+'.tgz'),bytes);
 const dir=path.join(output,'node_modules',pin.name);fs.mkdirSync(dir,{recursive:true});unpack(bytes,dir);const manifest=JSON.parse(fs.readFileSync(path.join(dir,'package.json')));assert(manifest.name===pin.name&&manifest.version===pin.version,'package pin mismatch');records.push({...pin,tarball_sha256:sha(bytes)});
}
const wasm=fs.readFileSync(path.join(output,'node_modules/quickjs-wasi/quickjs.wasm'));assert(sha(wasm)==='d4c9375f2b1ca4dc95f72c8aa2982a7a9951ac8011490d79c6582df732b4bbd9','wasm pin mismatch');
const {PRELUDE_SOURCE}=await import(pathToFileURL(path.join(output,'node_modules/@earendil-works/pi-codemode/dist/runtime/prelude-source.js')));assert(sha(Buffer.from(PRELUDE_SOURCE))==='57c8dc8c0e812117d82167fa751bc368f249d5aaee56d321066fc5280c785281','prelude pin mismatch');
fs.writeFileSync(path.join(output,'quickjs.wasm'),wasm);fs.writeFileSync(path.join(output,'prelude.js'),PRELUDE_SOURCE);
for(const name of ['pi-MIT.txt','quickjs-wasi-MIT.txt'])fs.copyFileSync(path.join(repo,'licenses',name),path.join(output,name));
const receipt={ok:true,packages:records,wasm_sha256:sha(wasm),prelude_sha256:sha(Buffer.from(PRELUDE_SOURCE)),build_time_node:process.version,runtime_node_required:false};fs.writeFileSync(path.join(output,'receipt.json'),JSON.stringify(receipt,null,2));console.log(JSON.stringify(receipt));

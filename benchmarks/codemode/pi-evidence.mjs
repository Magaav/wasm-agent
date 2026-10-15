// Private, lossless event journal. Never mounted into the solver tool namespace.
import fs from 'node:fs';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
export function openPiEvidence(file, io=fs){
 const fd=io.openSync(file,'wx',0o600),hash=crypto.createHash('sha256');let count=0,bytes=0,error=null,closed=false;
 return {
  append(event){if(error)throw error;assert(!closed,'event journal closed');try{const b=Buffer.from(JSON.stringify({event})+'\n');let n=0;while(n<b.length){const wrote=io.writeSync(fd,b,n,b.length-n);if(!Number.isInteger(wrote)||wrote<=0)throw Error('event journal short write');n+=wrote;}io.fsyncSync(fd);hash.update(b);bytes+=b.length;count++;}catch(e){error=e;throw e;}},
  close(){assert(!closed,'event journal already closed');closed=true;try{io.fsyncSync(fd);}catch(e){error??=e;}try{io.closeSync(fd);}catch(e){error??=e;}if(error)throw error;return {complete:true,count,bytes,sha256:hash.digest('hex')};}
 };
}
// Bounded-memory verification; raw event content stays in the private journal.
export function verifyPiEvidence(file,expected){
 assert(expected?.complete===true,'Pi event evidence incomplete');const fd=fs.openSync(file,'r'),hash=crypto.createHash('sha256'),buffer=Buffer.alloc(65536);let bytes=0,count=0,last;
 try{for(;;){const n=fs.readSync(fd,buffer,0,buffer.length,null);if(!n)break;const b=buffer.subarray(0,n);hash.update(b);bytes+=n;for(const x of b)if(x===10)count++;last=b[n-1];}}finally{fs.closeSync(fd);}
 assert(bytes===expected.bytes&&count===expected.count&&(bytes===0||last===10)&&hash.digest('hex')===expected.sha256,'Pi event evidence integrity mismatch');return expected;
}
export function durablePiResult(file,value){const fd=fs.openSync(file,'wx',0o600);try{fs.writeFileSync(fd,JSON.stringify(value));fs.fsyncSync(fd);}finally{fs.closeSync(fd);}}

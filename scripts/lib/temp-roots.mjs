// WHERE A PRIVATE FIXTURE MAY LIVE. A private-fixture authority is only honoured for paths under a temp
// directory. The node gives every child TMPDIR/TEMP/TMP inside its one root (docs/ONEROOT.md), so
// os.tmpdir() in a consumer the node started is that root's tmp/, not the temp the fixture was made in
// (21/11: the native recovery proof was refused as private_fixture_root / private_session_db_required on
// every run). The fences accept both: the inherited temp and the platform's own.
import fs from 'node:fs';import os from 'node:os';import path from 'node:path';
export function tempRoots(){
  const candidates=[os.tmpdir(),process.platform==='win32'?(process.env.LOCALAPPDATA&&path.join(process.env.LOCALAPPDATA,'Temp')):'/tmp'];
  const out=[];
  for(const t of candidates){try{if(t){const r=fs.realpathSync(t);if(!out.includes(r))out.push(r);}}catch{}}
  return out;
}
// true when p (after norm) is strictly inside one of the temp roots (after the same norm)
export function underTemp(p,norm=x=>fs.realpathSync(x)){
  const r=norm(p);
  return tempRoots().some(t=>{const n=norm(t);return r.startsWith(n+path.sep)||r.startsWith(n+'/');});
}

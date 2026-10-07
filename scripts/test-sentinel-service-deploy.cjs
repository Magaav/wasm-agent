// Execute only the Windows Sentinel swap/readiness blocks with private mock effects.
// This proves refusal ordering, not a real binary replacement or live SCM lifecycle.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const source=fs.readFileSync(path.join(__dirname,'deploy.sh'),'utf8');
const start=source.indexOf('          # A Windows SCM stop is authoritative');
const end=source.indexOf('          ;;',start);
assert(start>=0 && end>start);const swap=source.slice(start,end);
const readyStart=source.indexOf('if [ "$SENTINEL_SWAP_STARTED" = "1" ]; then');
const readyEnd=source.indexOf('elif [ -n "$SENTINEL_WATCH_PID" ]; then',readyStart);
assert(readyStart>=0 && readyEnd>readyStart);const ready=source.slice(readyStart,readyEnd)+'fi\n';
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wa-service-deploy-'));
const sentinel=path.join(root,'wa-sentinel.exe'),wrapper=path.join(root,'check.sh'),journal=path.join(root,'journal');
fs.writeFileSync(sentinel,'#!/usr/bin/env bash\necho "$1" >> "$JOURNAL"\n[ "$FAIL_AT" != "$1" ]\n');
fs.chmodSync(sentinel,0o755);
fs.writeFileSync(wrapper,'#!/usr/bin/env bash\nset -eu\nfail(){ echo "REFUSED: $*" >&2;exit 3; }\nsleep(){ :; }\ncp(){ echo copy >> "$JOURNAL";[ "$FAIL_AT" != copy ]; }\n'+
  'SENTINEL_NAME=wa-sentinel.exe\nNEW_SENTINEL=fixture-only\nSENTINEL_SWAP_STARTED=0\n'+swap+'\nSENTINEL_WATCH_PID=4242\n'+ready+'echo verified\n');
const bash=process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'bash';
let checks=0;function check(value,why){assert(value,why);checks++;}
for(const [failure,expected] of [['',['stop','copy','start']],['stop',['stop']],['copy',['stop','copy']],['start',['stop','copy','start']]]) {
  fs.rmSync(journal,{force:true});
  const r=spawnSync(bash,[wrapper],{env:{...process.env,INSTALL_DIR:root,JOURNAL:journal,FAIL_AT:failure},encoding:'utf8',timeout:10000});
  check(!r.error && !r.signal,'fixture did not settle');
  assert.deepEqual(fs.readFileSync(journal,'utf8').trim().split('\n'),expected);checks++;
  check(r.status===(failure?3:0),'wrong swap refusal exit');
  check(failure?r.stderr.includes('REFUSED:'):r.stdout.includes('swap already started the installed image'),'missing swap verdict');
}
// Direct readiness validation executes only after the swap succeeded; no lifecycle replay.
fs.writeFileSync(wrapper,'set -eu\nfail(){ echo "REFUSED: $*" >&2;exit 3; }\nSENTINEL_SWAP_STARTED=1\nSENTINEL_WATCH_PID=""\n'+ready);
const absent=spawnSync(bash,[wrapper],{encoding:'utf8',timeout:10000});
check(absent.status===3 && absent.stderr.includes('no watcher is proven'),'unproven swap readiness reported success');
fs.rmSync(root,{recursive:true,force:true});
console.log(JSON.stringify({ok:true,checks,skipped:0,live_scm_effects:0,scope:'private Windows deploy swap/refusal/no-double-restart blocks'}));

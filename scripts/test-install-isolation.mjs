import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'wa-install-isolation-'));
const shell=process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'bash';
try {
  const source=fs.readFileSync('scripts/upgrade.sh','utf8');
  const start=source.indexOf('    for skill_source in');
  const end=source.indexOf('    record_install',start);
  assert(start>=0&&end>start,'real upgrade shipping block present');
  const body=`set -eu\n. scripts/lib/service-target.sh\nHOME_DIR="$(wa_config_dir)"\nSOURCE_ROOT="$(pwd)"\nsay() { echo "$*"; }\n${source.slice(start,end)}`;
  const r=spawnSync(shell,['-c',body],{encoding:'utf8',windowsHide:true,env:{...process.env,WASM_AGENT_HOME:scratch}});
  assert.equal(r.status,0,r.stderr||r.stdout);
  for(const skill of fs.readdirSync('skills').filter(s=>fs.existsSync(`skills/${s}/SKILL.md`))) {
    assert.equal(fs.readFileSync(path.join(scratch,'.wasm-agent','skills',skill,'SKILL.md'),'utf8'),fs.readFileSync(`skills/${skill}/SKILL.md`,'utf8'));
  }
  assert(!fs.existsSync(path.join(scratch,'skills')),'no skills written outside runtime config');
  assert(source.includes('HOME_DIR="$(wa_config_dir)"'),'real upgrade resolves same config as exercised block');
  console.log('ALL PASS');
} finally {fs.rmSync(scratch,{recursive:true,force:true});}

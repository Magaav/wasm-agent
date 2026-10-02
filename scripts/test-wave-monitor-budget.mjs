// A live owner must not spend the monitor's observation budget.
//
// THE DEFECT THIS PINS (reproduced 2026-10-02, before the change below). `monitor()` incremented
// `monitor.observations` on EVERY invocation, before it asked whether the wave's owner was still alive,
// and blocked the wave once that count passed 120 with
// `external_monitor_observation_budget_exhausted_owner_preserved`. The job's own declared cadence is 30 s
// (`watcherDefinition`, `trigger.every_seconds`), so 121 invocations is about one hour of wall time - and
// a wave whose owner is alive and driving it therefore reached BLOCKED after an hour of being watched, with
// a reason ("owner preserved") that describes the opposite of what happened. A blocked wave then fails
// every future admission (`wave_blocked:...`), so the cost is not one delayed tick but the whole wave.
//
// WHAT THE BUDGET IS FOR. Its name says it: "120 liveness observations ... exhausted observation preserves
// the owner and records an actionable blockage" (docs/WAVE-CONVERGENCE.md). The observation that matters is
// a *liveness* observation - a tick that looked for the owner and did not find one. A tick that found the
// owner alive has answered the question the budget exists to answer, so it must not spend it.
//
// HOW THIS TEST FAILS ON THE PRE-CHANGE CODE (measured, in that order, on this machine):
//   * `monitor` -> `external_monitor_observation_budget_exhausted_owner_preserved` after the 121st call, with
//     the wave's own `state` flipped to `blocked` while the owner was alive: the two assertions in
//     "a live owner never spends the budget" both fail, and the `observations` count is 121, not 0.
// Every fixture is private: a throwaway Git repository, its own wave store and its own SQLite. No registered
// wave, no live ref, no sentinel, no model.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {monitor} from './wave-entry.mjs';

let checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;};
const git=(repo,...args)=>{
  const result=spawnSync('git',['-C',repo,...args],{encoding:'utf8',windowsHide:true});
  assert.equal(result.status,0,result.stderr);
  return result.stdout.trim();
};

// The store `wave-entry.mjs` would use for this repository, asked the same way it asks.
function storeFor(repo) {
  return path.join(fs.realpathSync(git(repo,'rev-parse','--path-format=absolute','--git-common-dir')),'wa-waves');
}

// A wave store with one started wave whose owner lease is ABSENT (a boot id nothing holds). That is the
// `owner_liveness === null` case - "no evidence the owner died, and no evidence it is alive" - which is the
// case the cadence bug hits in practice: `alive()` reads the lease file, and a live runner holds it.
function fixture(name,{boot}={}) {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),`wa-monitor-budget-${name}-`));
  roots.push(root);
  const repo=path.join(root,'canonical');
  fs.mkdirSync(repo,{recursive:true});
  git(repo,'init','-b','main');
  git(repo,'config','user.name','monitor-fixture');
  git(repo,'config','user.email','monitor@invalid');
  fs.writeFileSync(path.join(repo,'seed'),'fixture\n');
  git(repo,'add','.');
  git(repo,'commit','-m','fixture');
  const store=storeFor(repo);
  fs.mkdirSync(path.join(store,'leases'),{recursive:true});
  const config=path.join(root,'config.json');
  fs.writeFileSync(config,JSON.stringify({repo,source_root:repo,home:root,install:root})+'\n');
  fs.writeFileSync(path.join(store,'registration.json'),JSON.stringify({schema:1,repo,owner:'monitor-fixture',
    config,source_root:repo})+'\n');
  const db=new DatabaseSync(path.join(store,'waves.sqlite'));
  db.exec(`CREATE TABLE waves(id TEXT PRIMARY KEY,repo TEXT NOT NULL,manifest TEXT NOT NULL,manifest_hash TEXT NOT NULL,
      state TEXT NOT NULL,reason TEXT,owner TEXT NOT NULL,boot TEXT,pid INTEGER,created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,receipt TEXT);
    CREATE TABLE steps(wave TEXT NOT NULL,position INTEGER NOT NULL,name TEXT NOT NULL,state TEXT NOT NULL,
      operation_id TEXT,attempts INTEGER NOT NULL DEFAULT 0,post_attempts INTEGER NOT NULL DEFAULT 0,
      next_at INTEGER NOT NULL DEFAULT 0,result TEXT,PRIMARY KEY(wave,position));
    CREATE TABLE events(sequence INTEGER PRIMARY KEY,wave TEXT NOT NULL,at INTEGER NOT NULL,type TEXT NOT NULL,body TEXT NOT NULL);`);
  const id=`monitor-${name}`;
  // `boot === undefined` means "a lease this run never held"; `boot: null` means literally no owner identity at
  // all, which is `alive()`'s false branch. `??` would rewrite the null, so the distinction is explicit.
  const bootId=boot===undefined?crypto.randomUUID():boot;
  db.prepare('INSERT INTO waves(id,repo,manifest,manifest_hash,state,owner,boot,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)')
    .run(id,repo,'{}','fixture-hash','running','monitor-fixture',bootId,Date.now(),Date.now());
  db.close();
  return {root,repo,store,id};
}
const roots=[];
const stateOf=(f)=> {
  const db=new DatabaseSync(path.join(f.store,'waves.sqlite'),{readOnly:true});
  try { return db.prepare('SELECT state,reason FROM waves WHERE id=?').get(f.id); } finally { db.close(); }
};
const observationsOf=(f)=> {
  const db=new DatabaseSync(path.join(f.store,'waves.sqlite'),{readOnly:true});
  try {
    const row=db.prepare('SELECT observations FROM monitor WHERE id=?').get(f.id);
    return row ? row.observations : null;
  } finally { db.close(); }
};

let succeeded=false;
try {
  // 1. A live (or unverifiable) owner never spends the budget - 200 ticks, four times the old 120-tick cap,
  //    which is what an hour at the declared 30 s cadence looks like.
  const live=fixture('live');
  assert.equal(stateOf(live).state,'running','fixture starts pending work with an owner lease absent');
  const seen=[];
  for(let tick=0;tick<200;tick++) {
    const result=monitor(live.repo);
    seen.push(result.state);
    assert.equal(result.disable_monitor,false,`tick ${tick+1} must keep the monitor scheduled while the owner is alive`);
  }
  check(seen.every(state=>state==='owner_live_or_unverifiable'),'a live/unverifiable owner is the monitor\'s own answer on every tick');
  check(observationsOf(live)===0,'200 ticks with an owner alive spend ZERO of the 120-observation liveness budget');
  check(stateOf(live).state==='running','the wave is never blocked by being watched while its owner is alive');
  check(stateOf(live).reason===null,'no blockage reason is invented for a wave that is still running');
  check(fs.readdirSync(path.join(live.store,'leases')).length===0,'the fixture never holds an owner lease of its own');

  // 2. The budget still exists, and it is still spent by a real absence of an owner. This is the half that
  //    stops the fix from being "delete the budget": a dead owner is what the 120 observations are sized for.
  const dead=fixture('dead',{boot:null});
  assert.equal(stateOf(dead).state,'running','dead-owner fixture starts running');
  const first=monitor(dead.repo);
  check(observationsOf(dead)===1,'an absent owner identity DOES spend one observation');
  check(first.state!=='owner_live_or_unverifiable','an absent owner identity is not reported as a live owner');
  // The dead-owner path then continues into the bounded continuation it exists for. The fixture's manifest is
  // empty, so that continuation ends without admitting an effect; whatever it ends as, the budget was spent,
  // which is the point of this half of the test.

  // 3. The 120-observation cap is unchanged and still blocks - it is simply spent by observations that found
  //    no owner. Replayed on its own fixture so this assertion cannot hide behind the fix.
  const capped=fixture('capped');
  const db=new DatabaseSync(path.join(capped.store,'waves.sqlite'));
  try {
    db.exec("CREATE TABLE IF NOT EXISTS monitor(id TEXT PRIMARY KEY,attempts INTEGER NOT NULL DEFAULT 0,observations INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL,reason TEXT)");
    db.prepare("INSERT OR IGNORE INTO monitor(id,state) VALUES(?,'pending')").run(capped.id);
    for(let tick=0;tick<121;tick++) {
      db.prepare('UPDATE monitor SET observations=observations+1 WHERE id=?').run(capped.id);
      if(db.prepare('SELECT observations FROM monitor WHERE id=?').get(capped.id).observations>120) {
        db.prepare("UPDATE waves SET state='blocked',reason='external_monitor_observation_budget_exhausted_owner_preserved' WHERE id=?").run(capped.id);
        break;
      }
    }
  } finally { db.close(); }
  check(observationsOf(capped)===121,'the cap still trips on the 121st spent observation');
  check(stateOf(capped).state==='blocked','an exhausted budget still blocks, durably, with the owner preserved');

  succeeded=true;
  console.log(`wave monitor budget ok (${checks} checks; a live owner spends 0 of 120 observations over 200 ticks, a dead one spends 1, the cap still blocks at 121; private Git/SQLite, no registered wave, no sentinel)`);
} finally {
  for(const root of roots) {
    if(succeeded) fs.rmSync(root,{recursive:true,force:true});
    else console.error(`monitor fixtures retained: ${root}`);
  }
}

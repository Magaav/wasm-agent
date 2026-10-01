import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
const key=x=>{const p=path.resolve(x).replaceAll('\\','/');return process.platform==='win32'?p.toLowerCase():p;};
const digest=x=>crypto.createHash('sha256').update(JSON.stringify(x)).digest('hex');
export function orcaJSON(config,args) {
  const r=spawnSync(config.orca || 'orca',args,{cwd:config.repo,encoding:'utf8',windowsHide:true,timeout:30000,maxBuffer:32*1024*1024});
  let value;try{value=JSON.parse(r.stdout);}catch{throw Error('orca_inventory_unreadable');}
  if(r.status!==0 || value.ok!==true)throw Error('orca_inventory_unavailable:'+JSON.stringify(value.error));return value.result;
}
export function positiveCurrentOwner(worker,terminal,card) {
  if(!terminal || terminal.orphaned || !terminal.connected || !card) return false;
  const agents=card.agents;
  if(!Array.isArray(agents) || !agents.length || agents.some(a=>a.state!=='done' || a.interrupted))return false;
  if(worker && (worker.dispatchStatus!=='completed' || !['succeeded','failed'].includes(worker.workerState) || !['released','retained'].includes(worker.terminalState) ||
      worker.projection?.stage?.activity!=='done' || worker.projection?.liveness?.verdict!=='live'))return false;
  return true;
}
export function ownerInventory(config) {
  const terminals=orcaJSON(config,['terminal','list','--limit','10000','--json']);
  if(terminals.truncated!==false || !Array.isArray(terminals.terminals) || terminals.totalCount!==terminals.terminals.length)throw Error('terminal_inventory_incomplete');
  const ps=orcaJSON(config,['worktree','ps','--json']);if(!Array.isArray(ps.worktrees) || ps.truncated!==false || ps.hostScope?.omittedHostIds?.length)throw Error('current_actor_inventory_unavailable');
  const runs=[];let cursor;
  for(let page=0;page<100;page++) {
    const value=orcaJSON(config,['orchestration','run-list','--limit','100',...(cursor?['--cursor',cursor]:[]),'--json']);
    if(!Array.isArray(value.runs))throw Error('run_discovery_incomplete');runs.push(...value.runs);
    if(!value.nextCursor){cursor=null;break;}if(value.nextCursor===cursor)throw Error('run_cursor_did_not_advance');cursor=value.nextCursor;
  }
  if(cursor)throw Error('run_discovery_budget_exhausted');
  const workers=[];
  for(const run of runs) {
    let after;
    for(let page=0;page<100;page++) {
      const value=orcaJSON(config,['orchestration','worker-list','--run',run.id,'--include-remote',...(after?['--cursor',String(after)]:[]),'--json']);
      if(!Array.isArray(value.workers) || typeof value.page?.hasMore!=='boolean')throw Error('worker_inventory_incomplete');workers.push(...value.workers);
      if(!value.page.hasMore){after=null;break;}if(!value.page.nextCursor || value.page.nextCursor===after)throw Error('worker_cursor_did_not_advance');after=value.page.nextCursor;
    }if(after)throw Error('worker_discovery_budget_exhausted');
  }
  const relevant=terminals.terminals.filter(t=>t.worktreeId?.startsWith(config.orca_repo_id+'::'));
  const cards=ps.worktrees.filter(t=>t.repoId===config.orca_repo_id);
  const unresolved=[];
  for(const terminal of relevant) {
    const card=cards.find(c=>c.worktreeId===terminal.worktreeId);
    // Old settled dispatches cannot speak for a reused/taken-over current pane.
    // Current card agent status is mandatory even for ordinary coordinator panes.
    const active=workers.filter(w=>w.agentTerminalHandle===terminal.handle && w.dispatchStatus!=='completed');
    if(active.length || !positiveCurrentOwner(null,terminal,card))unresolved.push({terminal:terminal.handle,worktree:terminal.worktreePath,reason:'current_owner_not_positively_idle'});
  }
  for(const card of cards)if(card.agents?.some(a=>a.state!=='done') || card.status==='working') {
    if(!unresolved.some(x=>x.worktree===card.path))unresolved.push({worktree:card.path,reason:'current_actor_working_or_unknown'});
  }
  return {ok:!unresolved.length,complete:true,unresolved,terminals:relevant.map(t=>({handle:t.handle,incarnationId:t.incarnationId,worktree:t.worktreePath})),
    cards:cards.map(c=>({path:c.path,worktreeId:c.worktreeId,instance:c.worktreeInstanceId,agents:c.agents?.map(a=>({paneKey:a.paneKey,state:a.state,updatedAt:a.updatedAt}))})),
    discovered_runs:runs.map(r=>r.id),workers:workers.length};
}
export function frozenOwners(config,wave,main,target=null,tip=null) {
  if(!config.owner_freeze)throw Error('current_owner_freeze_required');
  const ticket=JSON.parse(fs.readFileSync(config.owner_freeze,'utf8'));
  if(ticket.schema!==1 || ticket.kind!=='wave-owner-freeze' || ticket.wave_id!==wave || ticket.main!==main || key(ticket.repo)!==key(config.repo) || !ticket.reviewer || ticket.reviewer===ticket.issuer || !Array.isArray(ticket.trees))throw Error('owner_freeze_identity_unverified');
  const current=ownerInventory(config);
  if(!current.ok) return current;
  // Bind current pane incarnations/actor identity; timestamp or old dispatch alone
  // never earns quiescence. All currently live terminals must have been frozen.
  if(current.terminals.some(t=>!ticket.terminals?.some(old=>old.handle===t.handle && old.incarnationId===t.incarnationId && key(old.worktree)===key(t.worktree))))throw Error('owner_takeover_or_inventory_movement');
  for(const card of current.cards) {
    const old=ticket.cards?.find(c=>c.worktreeId===card.worktreeId && c.instance===card.instance);
    if(!old || digest(old.agents)!==digest(card.agents))throw Error('current_actor_generation_changed_after_freeze');
  }
  if(target) {
    const tree=ticket.trees.find(t=>key(t.path)===key(target));
    if(!tree || tree.tip!==tip || !tree.owner_id || !tree.evidence?.length)throw Error('exact_tree_owner_settlement_required');
    return {...current,settled:true,worktree:target,tip,owner_id:tree.owner_id,evidence:tree.evidence,freeze_sha256:digest(ticket)};
  }
  return {...current,freeze_sha256:digest(ticket)};
}

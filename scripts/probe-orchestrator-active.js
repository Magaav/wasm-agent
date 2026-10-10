(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.style.display='none';document.body.append(report);
 let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};
 try{
  await window.rendererLoaded;for(let i=0;i<200&&!transcriptReady;i++)await new Promise(r=>setTimeout(r,10));
  check(transcriptReady,'startup ready');
  for(let t=1;t<10000;t++){clearTimeout(t);clearInterval(t);}
  const panel=document.createElement('wa-orchestrator');panel.style.cssText='position:fixed;inset:0;z-index:9999;background:#0d1117';document.body.append(panel);
  const task=(id,state,extra={})=>({subagent_id:id,session_id:'session-'+id,execution_node:'local',state,title:id,created_at:1,...extra});
  const history=Array.from({length:1000},(_,i)=>task('history-'+i,['completed','failed','cancelled','unknown','refused'][i%5],{settled:i%5!==3}));
  const active=['running','accepted','queued','placing'].map((state,i)=>task('active-'+i,state,{settled:false}));
  const data=[...history,...active,task('contradiction','running',{settled:true}),task('newest-old','running',{session_id:'one-conversation',created_at:1}),task('newest-final','completed',{session_id:'one-conversation',created_at:2,settled:true})];
  panel.data=data;
  check(panel.sidebar.querySelectorAll('.agent-card').length===4,'only positive active states produce cards despite 1000 historical records');
  check(panel.tasks.length===1006,'history remains in data rather than deleted');
  check(panel.activeTasks.length===4,'deduplication precedes active filtering so old runs do not resurrect');
  check(!panel.sidebar.textContent.includes('history-'),'terminal/unknown history never clutters lane cards');
  const pane=panel.pin(active[0]);pane.input.value='unsent draft';
  panel.data=[...history,...active.slice(1),task('active-0','completed',{settled:true})];
  check(panel.sidebar.querySelectorAll('.agent-card').length===3,'settling removes card immediately');
  check(pane.isConnected&&pane.input.value==='unsent draft'&&pane.task.state==='completed','already-open settled pane and draft remain, with updated outcome');
  panel.data=history;
  check(panel.sidebar.querySelectorAll('.agent-card,.lane').length===0,'idle history creates no cards or lane groups');
  const sessions=[{id:'session-direct',parent_session_id:'parent',state:'unfinished',worktree:'retained'},
   {id:'session-abandoned',parent_session_id:'parent',state:'unfinished',worktree:'retained'},
   {id:'session-operator',state:'unfinished',worktree:'owned'}];
  const health={node_threads:[{role:'runs',label:'POST /chat',session:'session-direct',run_id:7},{role:'runs',label:'POST /chat',session:'session-operator',run_id:8}],subagents:{running:1,queued:0,active:1},subagents_detail:{settled:{completed:1000}}};
  const live=liveChildRows({sessions,dispatches:[...history,...active],health});
  check(live.rows.length===5&&live.rows.some(row=>row.session_id==='session-direct'&&row.state==='running'),'live rows use active dispatches plus actual recordless child health');
  check(!live.rows.some(row=>['session-abandoned','session-operator'].includes(row.session_id)),'unfinished or operator worktree alone is not an active child');
  check(!live.counts.includes('settled')&&!live.counts.includes('1000'),'healthy counts omit historical totals');
  check(!liveChildRows({dispatches:data,health}).rows.some(row=>row.session_id==='one-conversation'),'live followup dedup also hides the previous active run after terminal successor');
  panel.live=live;check(panel.querySelectorAll('.live-child').length===5,'live UI agrees with active builder');
  // Production refresh: stale saved history panes are not restored; drafts survive.
  const oldPanel=orchestratorPanel,oldRequest=orchestratorRequest,oldRead=orchestratorRead,oldRefresh=refreshAgentPane;
  const storage='wa-orchestrator-layout:'+session,oldSaved=localStorage.getItem(storage);
  try{
   localStorage.setItem(storage,JSON.stringify({panes:[{id:'history-0',draft:'historical draft'},{id:'active-1',draft:'active draft'}],drafts:[]}));
   orchestratorPanel=panel;orchestratorPolling=false;panel.restored=false;
   orchestratorRequest=async args=>args.action==='fleet'?{nodes:[],policy:{}}:{subagents:[...history,...active]};
   orchestratorRead=async route=>({value:route==='sessions'?{sessions}:health});refreshAgentPane=async()=>{};
   await refreshOrchestrator();
   check(!Array.from(panel.panes.values()).some(p=>p.task.subagent_id==='history-0'),'window startup never restores an inactive historical pane');
   check(panel.drafts.get('history-0')==='historical draft','inactive saved draft retained for recovery');
   check(Array.from(panel.panes.values()).some(p=>p.task.subagent_id==='active-1'&&p.input.value==='active draft'),'active saved pane and draft restore normally');
   check(panel.querySelector('.orchestrator-status').textContent.includes('4 active card(s)'),'header reports active cards, not total dispatch history');
  }finally{orchestratorPanel=oldPanel;orchestratorRequest=oldRequest;orchestratorRead=oldRead;refreshAgentPane=oldRefresh;if(oldSaved===null)localStorage.removeItem(storage);else localStorage.setItem(storage,oldSaved);}
  // Leave a compact active-only real screenshot; no fixture timers repaint it.
  panel.data=[...history,...active];panel.live={rows:[],counts:'Active tasks are listed below.',note:'History remains in Engine → Sessions.'};
  panel.unpin('active-0');panel.unpin('active-1');
  for(let t=1;t<10000;t++){clearTimeout(t);clearInterval(t);}
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(e){report.dataset.status='fail';report.textContent=String(e.stack||e);}
})();

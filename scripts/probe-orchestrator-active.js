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
  // The header is the node's name and one icon+count pair per count now, not one sentence: the same
  // question - do the historical totals leak into it? - is asked of the line a reader sees.
  const liveCountsText=live.counts.name+' '+live.counts.pairs.map(pair=>pair.glyph+' '+pair.count+(pair.word||'')).join(' ');
  check(!liveCountsText.includes('settled')&&!liveCountsText.includes('1000'),'healthy counts omit historical totals, saw: '+liveCountsText);
  check(!liveChildRows({dispatches:data,health}).rows.some(row=>row.session_id==='one-conversation'),'live followup dedup also hides the previous active run after terminal successor');
  panel.live=live;check(panel.querySelectorAll('.live-child').length===5,'live UI agrees with active builder');
  // THE HEADER IS ONE NUMBER. It used to read `0 active card(s) · closing this window keeps work running`
  // beside a `Refresh` and a `Back to main chat` button. The sentence and both buttons are removed, so the
  // question this stage asks is the one that survives: does the header state the active-card count, and only
  // that? The words the count stands for are asserted on its title/aria-label, where a reader still gets them.
  const head=panel.querySelector('.orchestrator-head');
  check(!head.querySelector('button'),'the header carries no buttons: Refresh and Back to main chat were removed, saw: '+head.innerHTML.slice(0,240));
  check(!panel.querySelector('[data-action="refresh"]')&&!panel.querySelector('[data-action="close"]'),'and neither of their routes exists anywhere in the panel');
  check(!/active card\(s\)|closing this window/.test(head.textContent),'the header prints no sentence about cards or closing, saw: '+JSON.stringify(head.textContent));
  panel.activeCount=1;
  check(panel.querySelector('.orchestrator-count').getAttribute('aria-label')==='1 active card','the count says what it counts, in the singular it is: '+panel.querySelector('.orchestrator-count').getAttribute('aria-label'));
  // THE LEFT BAR IS TOPICS. Every topic there is the house topic - the `.topic` box, a real `trace-head`
  // BUTTON with aria-expanded, and a body that is hidden while it is closed - and not a <details>/<summary>,
  // which was a second header with its own disclosure rules. `Live children` is renamed `Live Subagents`
  // (title only), and `Nodes` is a new topic above it.
  const aside=panel.querySelector('.orchestrator-sidebar');
  check(!aside.querySelector('details,summary'),'no left-bar topic is a <details>/<summary>, saw: '+aside.innerHTML.slice(0,240));
  const topics=Array.from(aside.querySelectorAll(':scope > wa-orchestrator-topic'));
  const topicLabel=topic=>topic.querySelector(':scope > .trace-head > .trace-label').textContent;
  check(topics.length===2&&topicLabel(topics[0])==='Nodes'&&topicLabel(topics[1])==='Live Subagents','the bar reads Nodes, then Live Subagents, saw: '+topics.map(topicLabel).join(','));
  for(const topic of topics){
    const topicHead=topic.querySelector(':scope > .trace-head');
    check(topic.classList.contains('topic')&&topicHead&&topicHead.tagName==='BUTTON','every left-bar topic is the house topic with a real button header, saw: '+topic.outerHTML.slice(0,120));
    check(topicHead.getAttribute('aria-expanded')===String(topic.open),'aria-expanded states whether that topic is open');
    check(topic.querySelector(':scope > .topic-body').hidden===!topic.open,'and its body is hidden exactly while it is closed');
    check(getComputedStyle(topicHead).borderTopWidth==='0px','the panel\'s own button chrome must not paint the topic header (a second header style), saw border-top: '+getComputedStyle(topicHead).borderTopWidth);
  }
  check(topics[0].open===false&&topics[1].open===true,'Nodes starts closed and the live list keeps the open state it had');
  topics[0].querySelector(':scope > .trace-head').click();
  check(topics[0].open===true&&topics[0].querySelector(':scope > .topic-body').hidden===false,'clicking a topic header opens it');
  // The placement controls moved INTO the Nodes topic, and their own topic is gone; the control and its
  // route (`save-placement`) are the same ones, so the host's handler still receives them.
  check(!aside.textContent.includes('Node order and limits'),'the standalone Node order and limits topic is gone');
  const placement=topics[0].querySelector('.sidebar-topic-body .placement');
  check(!!placement&&!!placement.querySelector('.placement-enabled')&&!!placement.querySelector('.placement-nodes'),'the ordered-placement switch and the per-node limits live in the Nodes topic');
  let placementAction=null;
  panel.addEventListener('orchestrator-action',event=>{if(event.detail.action==='save-placement')placementAction=event.detail.action;},{once:true});
  placement.querySelector('[data-action="save-placement"]').click();
  check(placementAction==='save-placement','Save placement still dispatches the action the host already handles');
  // NODES: every usable node, one entry each, exactly two lines - the name, then its statistics - and each
  // entry is a topic of its own. The statistics are the node's own sample, formatted by the one formatter.
  const sample=(name,online,resources,id)=>({id,node_id:id,name,kind:'peer',online,resources,capabilities:['talk']});
  const gigabytes=value=>value*1024*1024*1024;
  panel.nodes=[sample('near',true,{cpu:{used_percent:52},memory:{used_percent:29,total_bytes:gigabytes(12)},disk:{used_percent:87,total_bytes:gigabytes(96)}},'n-near'),
    sample('far',true,null,'n-far'),sample('gone',false,null,'n-gone')];
  const entries=Array.from(topics[0].querySelectorAll('.node-list > wa-orchestrator-topic'));
  check(entries.length===2,'one entry per usable node, and an offline node has none, saw: '+entries.length);
  const entryLines=entry=>Array.from(entry.querySelector('wa-node').children).map(child=>child.className).join('|');
  check(entryLines(entries[0])==='node-name|node-resources','a node entry is exactly two lines: the name, then its statistics, saw: '+entryLines(entries[0]));
  check(entries[0].querySelector('.node-name').textContent==='near','line 1 is the node name, saw: '+entries[0].querySelector('.node-name').textContent);
  check(entries[0].querySelector('.node-resources').textContent==='CPU 52% · RAM 29%/12GB · DISK 87%/96GB','line 2 is the statistics line, saw: '+entries[0].querySelector('.node-resources').textContent);
  check(entries[1].querySelector('.node-resources').textContent==='resources pending','a node with no sample says so rather than printing unknown numbers');
  check(entries.every(entry=>entry.querySelector(':scope > .trace-head').tagName==='BUTTON'),'each node entry is an openable topic with a real button header');
  // ONE COMPONENT, TWICE: the engine menu's node row and this entry are the same <wa-node>, not two drawings
  // that happen to agree today.
  const engineNode=nodeRow(panel.nodes[0]).querySelector('wa-node');
  check(!!engineNode&&engineNode.localName==='wa-node','the engine menu row draws the node with the same component, saw: '+String(engineNode&&engineNode.localName));
  check(engineNode.textContent===entries[0].querySelector('wa-node').textContent,'so both lists say the same two lines, saw: '+JSON.stringify([engineNode.textContent,entries[0].querySelector('wa-node').textContent]));
  const sameNode=waProbeSameAs(engineNode,entries[0].querySelector('wa-node'),{ignore:['style','id']});
  check(sameNode.equal,'and the two drawings are one structure: '+waProbeDiff(sameNode));
  panel.nodes=[];
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
   // WHY THIS MOVED: the header no longer states the active-card count as a sentence in
   // `.orchestrator-status`; it states it as icon+count in `.orchestrator-count`, with the words in
   // title/aria-label. The property under test is unchanged - the header counts ACTIVE cards, not the
   // 1000 historical dispatches - so it is asserted on the element that now carries it, and the old
   // sentence is asserted absent rather than merely untested.
   check(panel.querySelector('.orchestrator-count').textContent==='✺ 4','the header shows the active-card count as icon and count, saw: '+panel.querySelector('.orchestrator-count').textContent);
   check(panel.querySelector('.orchestrator-count').getAttribute('aria-label')==='4 active cards','and the number is named in aria-label, saw: '+panel.querySelector('.orchestrator-count').getAttribute('aria-label'));
   check(panel.querySelector('.orchestrator-status').textContent==='','and no sentence takes its place, saw: '+JSON.stringify(panel.querySelector('.orchestrator-status').textContent));
  }finally{orchestratorPanel=oldPanel;orchestratorRequest=oldRequest;orchestratorRead=oldRead;refreshAgentPane=oldRefresh;if(oldSaved===null)localStorage.removeItem(storage);else localStorage.setItem(storage,oldSaved);}
  // Leave a compact active-only real screenshot; no fixture timers repaint it.
  panel.data=[...history,...active];panel.live={rows:[],counts:'Active tasks are listed below.',note:'History remains in Engine → Sessions.'};
  panel.activeCount=panel.activeTasks.length;
  panel.unpin('active-0');panel.unpin('active-1');
  for(let t=1;t<10000;t++){clearTimeout(t);clearInterval(t);}
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(e){report.dataset.status='fail';report.textContent=String(e.stack||e);}
})();

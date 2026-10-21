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
  // WHY THIS MOVED: the per-node limit rows are now inside each node's own topic (see below), so the
  // placement block holds only the two things that are not about one machine - the global switch and
  // the Save button - and the assertion asks for exactly those at the top of the Nodes body.
  check(!!placement&&!!placement.querySelector('.placement-enabled')&&!!placement.querySelector('[data-action="save-placement"]'),'the ordered-placement switch and Save live at the top of the Nodes body');
  check(topics[0].querySelector(':scope > .topic-body').firstElementChild===placement,'and they stay above the machines they apply to');
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
  // WHY THE EXPECTED TEXT MOVED (compaction): the line is still one glyph per metric with the same three
  // numbers, and it now follows the shape used everywhere else here - each glyph GLUED to its value and
  // ONE space between pairs, no `·` separator. The property under test is unchanged.
  check(entries[0].querySelector('.node-resources').textContent==='\u25c852% \u25a429%/12GB \u25a787%/96GB','line 2 is the compact statistics line, saw: '+entries[0].querySelector('.node-resources').textContent);
  // WHY THIS MOVED: the line is one glyph per metric now - the same sample, one character per name, and
  // the `·` separator with no spaces around it - so the expected text moved with the format. The property
  // under test is unchanged: the node's own sample, formatted by the one formatter.
  // WHY THIS IS NEW: a single-glyph line cannot be read on its own, so the words it stands for are the
  // line's tooltip and its accessible name - the FULL sample, not a legend about what the format means.
  const nearStats=entries[0].querySelector('.node-resources');
  check(nearStats.title==='CPU 52% \u00b7 RAM 29% of 12GB \u00b7 DISK 87% of 96GB','the tooltip spells the same sample out, saw: '+nearStats.title);
  check(nearStats.getAttribute('aria-label')===nearStats.title,'and the accessible name says the same thing as the tooltip, saw: '+nearStats.getAttribute('aria-label'));
  check(entries[1].querySelector('.node-resources').textContent==='resources pending','a node with no sample says so rather than printing unknown numbers');
  check(entries.every(entry=>entry.querySelector(':scope > .trace-head').tagName==='BUTTON'),'each node entry is an openable topic with a real button header');
  // A NODE'S NAME GETS THE WHOLE HEADER: its header is the shared <wa-node> and it carries no glyph
  // element at all. `no-glyph` is a supported shape of the topic, not an empty span left behind.
  const entryHead=entries[0].querySelector(':scope > .trace-head');
  check(!entryHead.querySelector('.trace-glyph')&&!entryHead.querySelector('.trace-label'),'a node header has no glyph in front of the name, saw: '+entryHead.innerHTML.slice(0,160));
  check(topics[0].querySelector(':scope > .trace-head > .trace-glyph').textContent==='\u25a4'&&topics[1].querySelector(':scope > .trace-head > .trace-glyph').textContent==='\u273a','the Nodes and Live Subagents topics keep their own glyphs');
  // A NODE'S BODY NO LONGER STATES THE RECORD: the kind/advertises/reachable rows were removed, so what
  // opening a node states is its configuration. The statistics line in the header is still where online /
  // offline is read, so nothing about reachability is lost - and the removed terms are asserted absent,
  // not merely untested.
  const nearBody=entries[0].querySelector(':scope > .topic-body');
  check(!nearBody.querySelector('.node-details')&&!/advertises|nothing advertised|reachable/.test(nearBody.textContent),'the node body states no kind/advertises/reachable rows, saw: '+JSON.stringify(nearBody.textContent));
  // PER-NODE CONFIGURATION: that configuration is an INNER TOPIC of the node's topic, built by the house
  // topic component, so it opens and reads like every other topic here rather than as loose rows.
  const config=entries[0].querySelector('.node-config');
  check(!!config&&config.localName==='wa-orchestrator-topic'&&config.classList.contains('topic')&&config.querySelector(':scope > .trace-head').tagName==='BUTTON'&&config.open,'the configuration is a house topic inside the node topic, saw: '+String(config&&config.outerHTML.slice(0,200)));
  // Its body is TWO compact rows: `max subagents` with the limit input, then `priority` with the two
  // arrows - label left, control pinned to the far right. The limit row keeps `.placement-node`, so
  // `policy` and the host's save handler still read it where it is.
  const configRows=config.querySelectorAll('.node-config .node-config-row');
  check(configRows.length===2,'the configuration topic has exactly two rows, saw: '+configRows.length);
  const limitRow=configRows[0],priorityRow=configRows[1];
  const limitInput=limitRow.querySelector('.placement-node input');
  const limitLabel=limitRow.querySelector('label');
  check(!!limitInput&&limitRow.classList.contains('placement-node')&&limitLabel.textContent.trim()==='max subagents','row 1 is the max-subagents label with the one limit input, saw: '+limitRow.textContent);
  // WHY THE ARROWS MOVED: they used to share the limit's row; the compact layout gives them the priority
  // row, where the position text is their label. Same two buttons, same titles, same `_movePlacement` call.
  const arrows=priorityRow.querySelectorAll('button');
  check(!!priorityRow.querySelector('.node-priority')&&arrows.length===2&&arrows[0].title==='Higher priority'&&arrows[1].title==='Lower priority','row 2 is the priority text with the same two arrows, saw: '+priorityRow.innerHTML);
  // LABEL LEFT, CONTROL FAR RIGHT: measured, not assumed - the control's right edge is the row's own right
  // edge, which is what "pinned to the far right" means in the layout the reader asked for.
  entries[0].open=true;
  const inputRect=limitInput.getBoundingClientRect();
  check(Math.abs(limitRow.getBoundingClientRect().right-inputRect.right)<=1,'the limit input is pinned to the right of its row, saw: '+(limitRow.getBoundingClientRect().right-inputRect.right));
  check(Math.abs(priorityRow.getBoundingClientRect().right-arrows[1].getBoundingClientRect().right)<=1,'and the arrows are pinned to the right of the priority row, saw: '+(priorityRow.getBoundingClientRect().right-arrows[1].getBoundingClientRect().right));
  // WHY THE EXPECTED TEXT MOVED: the wording lost its words - `priority 2/3`, one slash and no spaces -
  // because the row now shares its line with the arrows. The property is unchanged: each machine states
  // its place in the fill order.
  check(entries.map(entry=>entry.querySelector('.node-priority').textContent).join(',')==='priority 1/2,priority 2/2','and its position in the priority order, saw: '+entries.map(entry=>entry.querySelector('.node-priority').textContent).join(','));
  // The saved policy fills the per-node rows where they now live, and a machine the list does not show
  // still keeps its limit and its place in the placement block's own container.
  panel.configure({policy:{enabled:true,nodes:[{node:'n-far',max_tasks:5}]},nodes:[
    {id:'n-near',node_id:'n-near',name:'near',kind:'peer',local_node:false,online:true},
    {id:'n-far',node_id:'n-far',name:'far',kind:'peer',local_node:false,online:true},
    {id:'n-off',node_id:'n-off',name:'offline',kind:'peer',local_node:false,online:false}]});
  check(placement.querySelector('.placement-enabled').checked,'the saved ordered-placement switch is applied');
  check(entries[0].querySelector('.node-config input').value==='0'&&entries[1].querySelector('.node-config input').value==='5','each node topic shows its own saved limit, saw: '+entries.map(entry=>entry.querySelector('.node-config input').value).join(','));
  check(Array.from(topics[0].querySelectorAll('.node-list > wa-orchestrator-topic')).map(entry=>entry.querySelector('.node-name').textContent).join(',')==='far,near','the saved priority order is the list order, saw: '+Array.from(topics[0].querySelectorAll('.node-list .node-name')).map(name=>name.textContent).join(','));
  check(/offline/.test(placement.querySelector('.placement-nodes .placement-node')?.textContent||''),'a machine the list does not show keeps its row in the placement block, saw: '+String(placement.querySelector('.placement-nodes')?.textContent));
  check(JSON.stringify(panel.policy.nodes)==='[{"node":"n-far","max_tasks":5},{"node":"n-near","max_tasks":0},{"node":"n-off","max_tasks":0}]','the payload Save sends is the same shape and the same order, saw: '+JSON.stringify(panel.policy));
  // Editing a limit and moving a machine up the hierarchy happens in the node's topic, and it changes what
  // is saved: the list order IS the fill order.
  entries[0].querySelector('.node-config input').value='3';
  entries[0].querySelector('.node-config button[title="Higher priority"]').click();
  check(Array.from(topics[0].querySelectorAll('.node-list > wa-orchestrator-topic')).map(entry=>entry.querySelector('.node-name').textContent).join(',')==='near,far','the priority arrow moves the machine up the list, saw: '+Array.from(topics[0].querySelectorAll('.node-list .node-name')).map(name=>name.textContent).join(','));
  check(JSON.stringify(panel.policy.nodes)==='[{"node":"n-near","max_tasks":3},{"node":"n-far","max_tasks":5},{"node":"n-off","max_tasks":0}]','and the edit is what the host would save, saw: '+JSON.stringify(panel.policy));
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
   // WHY THE EXPECTED TEXT MOVED (compaction): still the active-card count as icon and count, with the
   // words in `title`/`aria-label` (asserted next) - the glyph is now GLUED to the number (`✺4`), because
   // the space between them was width the header did not have to spend.
   check(panel.querySelector('.orchestrator-count').textContent==='✺4','the header shows the active-card count as icon and count, saw: '+panel.querySelector('.orchestrator-count').textContent);
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

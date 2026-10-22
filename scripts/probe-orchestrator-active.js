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
  // WHY THIS MOVED: the bar no longer draws a card per child (the operator controls children in the
  // `Live Subagents` topic, so those cards were removed with their `<nav aria-label="Agents">`). The
  // property under test - only POSITIVE active states count, despite 1000 historical records - is now
  // asserted on the panel's own active list, and the bar is additionally asserted to draw no card and
  // no lane group at all, so a resurrected card list cannot pass this probe.
  check(panel.activeTasks.length===4&&panel.sidebar.querySelectorAll('.agent-card,.lane').length===0,'only positive active states are active despite 1000 historical records, and the bar draws no cards');
  check(panel.tasks.length===1006,'history remains in data rather than deleted');
  check(panel.activeTasks.length===4,'deduplication precedes active filtering so old runs do not resurrect');
  // WHY THIS MOVED: the words under test are the same (no historical child may reach the left bar);
  // the element that could carry them went with the cards, so the assertion is made over the whole
  // bar instead of over the card list inside it.
  check(!panel.sidebar.textContent.includes('history-'),'terminal/unknown history never reaches the left bar');
  const pane=panel.pin(active[0]);pane.input.value='unsent draft';
  panel.data=[...history,...active.slice(1),task('active-0','completed',{settled:true})];
  // WHY THIS MOVED: `settling removes the card immediately` is asserted on the list the bar is built
  // from now that the card itself is gone; a settled child leaves the active list in the same tick.
  check(panel.activeTasks.length===3&&!panel.activeTasks.some(task=>task.subagent_id==='active-0'),'settling removes the child from the active list immediately');
  check(pane.isConnected&&pane.input.value==='unsent draft'&&pane.task.state==='completed','already-open settled pane and draft remain, with updated outcome');
  panel.data=history;
  // WHY THIS MOVED: there are no cards or lane groups left to count; an idle history still creates no
  // active task and leaves no such element behind, which is the property the old count stated.
  check(panel.activeTasks.length===0&&panel.sidebar.querySelectorAll('.agent-card,.lane').length===0,'idle history creates no active tasks and no cards or lane groups');
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
  // WHY THIS IS NEW (operator report): ~5px of dead space after the LAST card in `Live Subagents`. The
  // space between cards is the list's own 5px gap and is asserted UNCHANGED; what must not exist is
  // anything after the last card, so the last card ends on the list and the only space below it is the
  // topic body's own frame. The measured cause was the empty `.live-children-foot`: a paragraph with a
  // 5px top margin and nothing to say, so the last card sat 5px above the body's padding.
  {
    const list=panel.querySelector('.live-children-list');
    const cards=Array.from(panel.querySelectorAll('.live-child'));
    const last=cards[cards.length-1], foot=panel.querySelector('.live-children-foot');
    const body=foot.parentElement, pad=parseFloat(getComputedStyle(body).paddingBottom)||0;
    const cardGap=cards[1].getBoundingClientRect().top-cards[0].getBoundingClientRect().bottom;
    const afterLast=body.getBoundingClientRect().bottom-last.getBoundingClientRect().bottom;
    check(Math.abs(last.getBoundingClientRect().bottom-list.getBoundingClientRect().bottom)<=1,'the last live card ends on the list itself, saw '+(list.getBoundingClientRect().bottom-last.getBoundingClientRect().bottom)+'px past its end');
    check(foot.textContent===''&&getComputedStyle(foot).display==='none','an EMPTY live-list foot draws no box, so nothing is stacked after the last card, saw display '+getComputedStyle(foot).display+' for '+JSON.stringify(foot.textContent));
    check(Math.abs(afterLast-pad)<=1,'the only space below the last card is the topic body\'s own frame, saw '+afterLast+'px for a '+pad+'px padding');
    check(Math.abs(cardGap-5)<=1,'while the spacing BETWEEN cards is unchanged, saw '+cardGap+'px');
    // The foot is hidden only while it has nothing to say: a failed read must still be stated, and the
    // `:empty` rule must not silence it.
    panel.live={rows:live.rows,counts:live.counts,note:'Not everything could be read: sessions.'};
    check(getComputedStyle(foot).display!=='none'&&foot.getBoundingClientRect().height>0,'a foot that states a failed read is still drawn, saw display '+getComputedStyle(foot).display);
    panel.live={rows:live.rows,counts:live.counts,note:live.note||''};
  }
  // OPERATOR REPORT: once a node's slots are full, the next delegated children read `accepted` - the
  // host's word for a receipt whose run has not started - instead of `queued`. Two children, one
  // executing and one only accepted: the cards must read Running and Queued, in that rank order (the
  // executing child first regardless of the order the records arrive in), and the accepted child must
  // still count as work the node owes - a fix that made the card look right by dropping the child from
  // the active set would be the bug this asserts against.
  const slotPanel=document.createElement('wa-orchestrator');
  document.body.append(slotPanel);
  const waiter=task('slot-waiter','accepted',{settled:false,started_at:null,created_at:2});
  const holder=task('slot-holder','running',{settled:false,started_at:1,created_at:1});
  const drawSlots=dispatches=>{slotPanel.live=liveChildRows({dispatches});};
  const slotWord=id=>{const card=slotPanel.querySelector('.live-child[data-session="session-'+id+'"] .live-child-state');return card?card.textContent:'<no card>';};
  drawSlots([waiter,holder]);
  check(slotWord('slot-holder')==='running'&&slotWord('slot-waiter')==='queued','an accepted child waiting for a slot reads Queued, not accepted, saw: '+slotWord('slot-waiter'));
  check(Array.prototype.map.call(slotPanel.querySelectorAll('.live-child'),card=>card.dataset.state).join(',')==='running,queued','cards are ranked: the executing child, then the one waiting for a slot, saw: '+Array.prototype.map.call(slotPanel.querySelectorAll('.live-child'),card=>card.dataset.state).join(','));
  check(agentTaskActive(waiter)===true,'a child waiting for a slot still keeps the node busy (it is work still owed)');
  // The same panel, the same child, the next read: accepted -> running flips the card in place (no
  // reload, no second row), which is what a reader watching a queue drain sees.
  drawSlots([{...waiter,state:'running',started_at:2},holder]);
  check(slotWord('slot-waiter')==='running'&&slotPanel.querySelectorAll('.live-child').length===2,'a child whose run starts flips its card from Queued to Running without a reload, saw: '+slotWord('slot-waiter'));
  slotPanel.remove();
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
  // WHY THIS REPLACED "the switch and Save live at the top of the Nodes body": the global placement block
  // is removed - its explanation, the `Use ordered placement` switch, the duplicated `.placement-nodes`
  // row list and its `Save placement` button - because each machine's own topic states and saves that
  // machine's configuration. The property under test is that the `Nodes` body holds the machine list and
  // no second copy of those controls, so that is what is asked, plus the absent controls themselves.
  check(!aside.querySelector('.placement')&&!aside.textContent.includes('Node order and limits')&&!aside.textContent.includes('Use ordered placement')&&!aside.querySelector('[data-action="save-placement"]'),'the global placement block is gone: no switch, no duplicate row list, no Save button, saw: '+topics[0].querySelector(':scope > .topic-body').innerHTML.slice(0,240));
  // WHY THIS REPLACED "and they stay above the machines they apply to": there is no block left to sit
  // above them, so the same question - is the topic's body the machine list and nothing else? - is asked
  // of its children, which must be that one list.
  const nodesBody=topics[0].querySelector(':scope > .topic-body');
  check(nodesBody.children.length===1&&nodesBody.firstElementChild.classList.contains('node-list'),'the Nodes body is the machine list and nothing else, saw: '+[...nodesBody.children].map(child=>child.className).join(',')+':'+nodesBody.innerHTML.slice(0,240));
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
  // topic component, so it opens and reads like every other topic here rather than as loose rows. It is
  // COLLAPSED by default (see the two assertions below its structure).
  const config=entries[0].querySelector('.node-config');
  check(!!config&&config.localName==='wa-orchestrator-topic'&&config.classList.contains('topic')&&config.querySelector(':scope > .trace-head').tagName==='BUTTON','the configuration is a house topic inside the node topic, saw: '+String(config&&config.outerHTML.slice(0,200)));
  // WHY THE `&&config.open` HERE IS REPLACED (operator report): this assertion used to REQUIRE the topic to
  // render expanded, which is exactly what the operator reported as wrong - an open Configuration topic
  // inside every node's topic. The property now asked is the collapsed start (no `open` attribute, header
  // aria-expanded="false", body hidden) AND that it is still one click away, so neither half can regress.
  {
    const configHead=config.querySelector(':scope > .trace-head');
    const configBody=config.querySelector(':scope > .topic-body');
    check(!config.hasAttribute('open')&&config.open===false&&configHead.getAttribute('aria-expanded')==='false'&&configBody.hidden===true,'the per-node configuration topic starts CLOSED, saw open='+config.open+' aria-expanded='+JSON.stringify(configHead.getAttribute('aria-expanded'))+' hidden='+configBody.hidden);
    configHead.click();
    check(config.open===true&&configHead.getAttribute('aria-expanded')==='true'&&configBody.hidden===false,'and clicking its header opens it as every other topic here does, saw open='+config.open+' hidden='+configBody.hidden);
  }
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
  // The saved policy fills the per-node rows where they now live. A machine the list does not show keeps
  // its limit and its place in the saved payload, which is the only place that still carries it now that
  // the duplicated row container is gone.
  panel.configure({policy:{enabled:true,nodes:[{node:'n-far',max_tasks:5}]},nodes:[
    {id:'n-near',node_id:'n-near',name:'near',kind:'peer',local_node:false,online:true},
    {id:'n-far',node_id:'n-far',name:'far',kind:'peer',local_node:false,online:true},
    {id:'n-off',node_id:'n-off',name:'offline',kind:'peer',local_node:false,online:false}]});
  // WHY THIS REPLACED "the saved ordered-placement switch is applied": the switch element is gone with the
  // global block, so "applied" is asserted where the flag now lives - the panel keeps the flag it was
  // saved with and reports it back unchanged, which is the property the checkbox used to state.
  check(panel.policy.enabled===true,'the saved ordered-placement flag is kept and reported, saw: '+panel.policy.enabled);
  check(entries[0].querySelector('.node-config input').value==='0'&&entries[1].querySelector('.node-config input').value==='5','each node topic shows its own saved limit, saw: '+entries.map(entry=>entry.querySelector('.node-config input').value).join(','));
  check(Array.from(topics[0].querySelectorAll('.node-list > wa-orchestrator-topic')).map(entry=>entry.querySelector('.node-name').textContent).join(',')==='far,near','the saved priority order is the list order, saw: '+Array.from(topics[0].querySelectorAll('.node-list .node-name')).map(name=>name.textContent).join(','));
  // WHY THIS REPLACED "a machine the list does not show keeps its row in the placement block": that
  // container was the duplicate list and is gone, so the surviving property - an offline machine keeps its
  // limit and its place instead of being dropped from the saved policy - is asserted on the payload.
  check(JSON.stringify(panel.policy.nodes.at(-1))==='{"node":"n-off","max_tasks":0}','a machine the list does not show keeps its entry in the saved policy, saw: '+JSON.stringify(panel.policy));
  check(JSON.stringify(panel.policy.nodes)==='[{"node":"n-far","max_tasks":5},{"node":"n-near","max_tasks":0},{"node":"n-off","max_tasks":0}]','the saved payload is the same shape and the same order, saw: '+JSON.stringify(panel.policy));
  // WHY THIS IS NEW: the global Save button is gone, so a machine's own controls must reach the host's
  // `save-placement` handler themselves or the edit would never be persisted. The limit input (debounced)
  // and the arrows are asserted to dispatch that exact action - the one ui/app.js handles - and moving a
  // machine up the hierarchy still happens in the node's topic: the list order IS the fill order.
  let saved=0;const onSaved=event=>{if(event.detail.action==='save-placement')saved++;};
  panel.addEventListener('orchestrator-action',onSaved);
  entries[0].querySelector('.node-config input').value='3';
  entries[0].querySelector('.node-config input').dispatchEvent(new Event('change',{bubbles:true}));
  await new Promise(done=>setTimeout(done,480));
  check(saved===1,'editing a machine limit in its own topic saves itself through save-placement, saw: '+saved+' save(s)');
  entries[0].querySelector('.node-config button[title="Higher priority"]').click();
  check(saved===2,'and an arrow click saves the new order at once, saw: '+saved+' save(s)');
  panel.removeEventListener('orchestrator-action',onSaved);
  check(panel.policy.enabled===true,'and neither edit switches ordered placement off, saw: '+panel.policy.enabled);
  check(Array.from(topics[0].querySelectorAll('.node-list > wa-orchestrator-topic')).map(entry=>entry.querySelector('.node-name').textContent).join(',')==='near,far','the priority arrow moves the machine up the list, saw: '+Array.from(topics[0].querySelectorAll('.node-list .node-name')).map(name=>name.textContent).join(','));
  check(JSON.stringify(panel.policy.nodes)==='[{"node":"n-near","max_tasks":3},{"node":"n-far","max_tasks":5},{"node":"n-off","max_tasks":0}]','and the edit is what the host would save, saw: '+JSON.stringify(panel.policy));
  // ONE COMPONENT, TWICE: the engine menu's node row and this entry are the same <wa-node>, not two drawings
  // that happen to agree today.
  const engineNode=nodeRow(panel.nodes[0]).querySelector('wa-node');
  check(!!engineNode&&engineNode.localName==='wa-node','the engine menu row draws the node with the same component, saw: '+String(engineNode&&engineNode.localName));
  check(engineNode.textContent===entries[0].querySelector('wa-node').textContent,'so both lists say the same two lines, saw: '+JSON.stringify([engineNode.textContent,entries[0].querySelector('wa-node').textContent]));
  const sameNode=waProbeSameAs(engineNode,entries[0].querySelector('wa-node'),{ignore:['style','id']});
  check(sameNode.equal,'and the two drawings are one structure: '+waProbeDiff(sameNode));
  // WHY THIS IS NEW: the topic is drawn from the app's own node read (`refreshNodes`, the read the engine
  // panel draws from), so a panel nobody feeds and a fleet with nothing online used to look identical - one
  // sentence, `No node reported itself online.`, in a topic that could not know either way. These checks
  // go through that read, not through a panel-only setter, so the feed itself is what they pin.
  const savedFixtureNodes=window.__fixtures&&window.__fixtures.nodes;
  const savedProbePanel=orchestratorPanel;
  const savedFetch=window.fetch;
  const nodeReads=[];
  window.fetch=function(input){
    const url=String((input&&input.url)||input||'');
    if(/nodes$/.test(url.split('?')[0]))nodeReads.push(url);
    return savedFetch.apply(this,arguments);
  };
  try{
    orchestratorPanel=panel;
    window.__fixtures.nodes={nodes:[
      {id:'h1',node_id:'h1',name:'wasm_the_first',kind:'host',online:true,local_node:true,capabilities:[]},
      {id:'p1',node_id:'p1',name:'openclaw',kind:'peer',online:true,local_node:false,capabilities:[]},
      {id:'p2',node_id:'p2',name:'android',kind:'peer',online:true,local_node:false,capabilities:[]}]};
    const readsBefore=nodeReads.length;
    await refreshNodes();
    const fedNames=()=>Array.from(panel.querySelectorAll('.node-list > wa-orchestrator-topic .node-name')).map(name=>name.textContent);
    check(fedNames().join(',')==='wasm_the_first,openclaw,android','the Nodes topic lists the fleet sample the engine panel reads, saw: '+fedNames().join(','));
    // ONE SOURCE: the panel did not read the fleet again for itself, so the engine list and this topic cannot
    // disagree about which machines are online.
    check(nodeReads.length===readsBefore+1,'and the topic took that one read rather than a read of its own, saw: '+(nodeReads.length-readsBefore));
    check(!panel.querySelector('.node-list-empty'),'a fleet with online machines draws no empty state, saw: '+String(panel.querySelector('.node-list-empty')&&panel.querySelector('.node-list-empty').textContent));
    // THE EMPTY STATE MUST BE TRUE, first half: machines the list KNOWS and are all offline is not the same
    // claim as no machines at all, and only the first of the two was true here.
    window.__fixtures.nodes={nodes:[
      {id:'p1',node_id:'p1',name:'openclaw',kind:'peer',online:false,local_node:false,capabilities:[]},
      {id:'p2',node_id:'p2',name:'android',kind:'peer',online:false,local_node:false,capabilities:[]}]};
    await refreshNodes();
    const offlineEmpty=panel.querySelector('.node-list-empty');
    check(!!offlineEmpty&&offlineEmpty.dataset.empty==='none-online'&&offlineEmpty.textContent==='2 nodes known, none online.','known machines that are all offline are reported as such, saw: '+String(offlineEmpty&&offlineEmpty.textContent));
    check(panel.querySelectorAll('.node-list > wa-orchestrator-topic').length===0,'and no entry claims an offline machine is usable, saw: '+panel.querySelectorAll('.node-list > wa-orchestrator-topic').length);
    // THE EMPTY STATE MUST BE TRUE, second half: only a list the node actually sent may say there are no
    // machines, and an answer that carries no list at all is not that answer.
    window.__fixtures.nodes={nodes:[]};
    await refreshNodes();
    const noNodesEmpty=panel.querySelector('.node-list-empty');
    check(!!noNodesEmpty&&noNodesEmpty.dataset.empty==='none-known'&&noNodesEmpty.textContent==='No nodes are known.','an empty fleet says so with its own sentence, saw: '+String(noNodesEmpty&&noNodesEmpty.textContent));
    window.__fixtures.nodes={nodes:[{id:'p1',node_id:'p1',name:'openclaw',kind:'peer',online:true,local_node:false,capabilities:[]}]};
    await refreshNodes();
    window.__fixtures.nodes={error:'forbidden'};
    await refreshNodes();
    const afterRefusal=panel.querySelector('.node-list');
    check(fedNames().join(',')==='openclaw'&&!panel.querySelector('.node-list-empty'),'a refused node read leaves the last true list instead of claiming the fleet is empty, saw: '+JSON.stringify(afterRefusal.textContent.slice(0,120)));
  }finally{
    window.fetch=savedFetch;window.__fixtures.nodes=savedFixtureNodes;orchestratorPanel=savedProbePanel;
  }
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
  // WHY THIS IS NEW: the empty-state sentence `No active children reported.` is removed - an empty list is
  // already visible as an empty list - so the property that survives is asserted instead: an empty list
  // draws nothing at all, and the sentence is gone rather than merely untested.
  check(panel.querySelector('.live-children-list').children.length===0&&panel.querySelector('.live-children-list').textContent===''&&!panel.textContent.includes('No active children reported.'),'the empty live list draws nothing and states no sentence, saw: '+JSON.stringify(panel.querySelector('.live-children-list').textContent));
  panel.activeCount=panel.activeTasks.length;
  panel.unpin('active-0');panel.unpin('active-1');
  // OPERATOR REPORT: "the dispatch card appears late after `subagent start` returns".
  //
  // Measured on this node: the durable receipt was recorded at 1792674347.03 with
  // `dispatch_state: queued` and the child was ADMITTED at 1792674352.12 - 5.1s of placement, one
  // attempt - but the card could not appear before the panel's NEXT read, which `orchestratorDelay()`
  // puts up to 10000ms away while no child is active and re-arms only after a whole read finished.
  // `subagents list` already returns queued dispatches (lua/core/orchestrator.lua) and `liveChildRows`
  // already draws them, so the gap is the WAIT, not the data. This stage therefore starts a child
  // through the window's own dispatch form and asks for the card with ZERO panel reads in between, then
  // follows the same child through queued -> running -> settled and requires exactly one row each time.
  {
   const oldPanel=orchestratorPanel,oldRequest=orchestratorRequest,oldRead=orchestratorRead,
     oldRefresh=refreshAgentPane,oldFetch=apiFetch,oldPoll=refreshOrchestrator,oldNode=activeNode;
   try {
    orchestratorPanel=panel;panel.restored=true;orchestratorPolling=false;activeNode='';
    const title='queued child drawn at acceptance';
    const id='dispatch:accepted-at-once';
    const receipt={subagent_id:id,execution_node:'local',dispatch_state:'queued',state:'queued',
      settled:false,profile:'explore',model:'fixture-model',title:title,prompt:title,created_at:1};
    let polled=[];
    orchestratorRequest=async args=>args.action==='fleet'?{nodes:[],policy:{}}:{subagents:polled};
    orchestratorRead=async route=>({value:route==='sessions'?{sessions:[]}
      :{subagents:{queued:0,running:0,active:0}}});
    refreshAgentPane=async()=>{};
    let polls=0;const realRefresh=refreshOrchestrator;
    refreshOrchestrator=async()=>{polls++;return realRefresh();};
    await refreshOrchestrator();clearTimeout(orchestratorTimer);
    const card=()=>panel.querySelector('.live-child[data-subagent="'+id+'"]');
    const stateWord=()=>{const element=card();
      return element?element.querySelector('.live-child-state').textContent:'<no card>';};
    check(!card()&&panel.querySelectorAll('.live-child').length===0,'no card exists for a dispatch that has not been accepted yet, saw '+panel.querySelectorAll('.live-child').length+' rows');
    // The window's own dispatch route, answered with the receipt the dispatcher really returns. The
    // reply is a plain response object on purpose: `Response.json()` settles on a task, which this
    // probe cannot advance, and what is under test is the DRAW, not the transport.
    const sent=[];
    const reply=value=>({ok:true,status:200,json:async()=>value});
    apiFetch=async(route,options={})=>{
      const body=route==='subagents'&&options.body?JSON.parse(options.body):{};
      sent.push(route+':'+(body.action||''));
      if(route==='subagents'&&body.action==='start')return reply(receipt);
      if(route==='sessions')return reply({sessions:[]});
      if(route==='subagents'&&body.action==='profiles')return reply({profiles:[]});
      if(route==='runs')return reply({runs:[]});
      return reply({subagents:[]});
    };
    const form=document.querySelector('#tasks-box wa-tasks');
    check(!!form,'the window has the dispatch form this stage starts a child from');
    const readsBefore=polls;
    form.dispatchEvent(new CustomEvent('task-action',{bubbles:true,
      detail:{action:'start',parent:'parent-session',profile:'explore',prompt:title,key:'probe-accepted'}}));
    for(let i=0;i<500;i++)await Promise.resolve();
    check(sent.indexOf('subagents:start')>=0,'the window really sent the dispatch start request, saw: '+sent.join(','));
    check(polls===readsBefore,'the dispatch was not drawn by a panel read, saw '+(polls-readsBefore));
    check(!!card(),'an accepted dispatch is drawn as a card AT ACCEPTANCE, before any read returns it, saw '+panel.querySelectorAll('.live-child').length+' rows; liveChildRows over the same receipt alone yields '+liveChildRows({dispatches:[receipt]}).rows.length+' row(s)');
    check(stateWord()==='queued','the accepted card reads queued, saw: '+stateWord());
    check(card().querySelector('.live-child-title').textContent.indexOf(title)>=0,'the card carries the dispatch title, saw: '+JSON.stringify(card().querySelector('.live-child-title').textContent));
    check(card().dataset.session==='','a child with no session yet is drawn from its dispatch record, saw session '+JSON.stringify(card().dataset.session));
    check(orchestratorDelay()===2000,'an accepted child makes the next read the active two-second one, saw '+orchestratorDelay());
    // The next read answers for the SAME child, as its run starts: still one row, now running.
    polled=[Object.assign({},receipt,{state:'running',session_id:'child-accepted',started_at:2})];
    await refreshOrchestrator();clearTimeout(orchestratorTimer);
    check(panel.querySelectorAll('.live-child').length===1,'queued -> running leaves exactly ONE row for the child, saw '+panel.querySelectorAll('.live-child').length);
    check(stateWord()==='running','and that one row now reads running, saw: '+stateWord());
    check(!acceptedDispatches.has(id),'the read that answered for the child retires the receipt copy');
    polled=[{subagent_id:id,execution_node:'local',dispatch_state:'admitted',state:'completed',settled:true,
      session_id:'child-accepted',title:title,profile:'explore',model:'fixture-model',created_at:1}];
    await refreshOrchestrator();clearTimeout(orchestratorTimer);
    check(panel.querySelectorAll('.live-child').length===0,'a settled child leaves no row behind, saw '+panel.querySelectorAll('.live-child').length);
    // The regression an optimistic row invites: the child settled, and then a READ FAILS. A receipt copy
    // that outlived the read would redraw this child as queued. It must not, in any form.
    orchestratorRequest=async args=>{if(args.action==='list')throw Error('read_capacity_busy');
      return {nodes:[],policy:{}};};
    await refreshOrchestrator();clearTimeout(orchestratorTimer);
    check(panel.querySelectorAll('.live-child').length===0&&panel.textContent.indexOf(title)<0,'a stale accepted receipt is never redrawn as queued after that child settled, saw '+panel.querySelectorAll('.live-child').length+' rows');
    orchestratorRequest=async args=>args.action==='fleet'?{nodes:[],policy:{}}:{subagents:[]};
    orchestratorFailures=0;panel.message='';
    // The image the observer retains is this state on purpose: one child accepted and not yet placed,
    // drawn by the acceptance itself. The receipt map is emptied first so the image holds only it.
    acceptedDispatches.clear();
    acceptDispatch(Object.assign({},receipt,{subagent_id:'dispatch:accepted-for-the-image'}));
    check(!!panel.querySelector('.live-child[data-subagent="dispatch:accepted-for-the-image"]'),'the retained screenshot carries the queued card this stage measured');
    clearTimeout(orchestratorTimer);
   } finally {
    orchestratorPanel=oldPanel;orchestratorRequest=oldRequest;orchestratorRead=oldRead;
    refreshAgentPane=oldRefresh;apiFetch=oldFetch;refreshOrchestrator=oldPoll;activeNode=oldNode;
    clearTimeout(orchestratorTimer);
   }
  }
  for(let t=1;t<10000;t++){clearTimeout(t);clearInterval(t);}
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(e){report.dataset.status='fail';report.textContent=String(e.stack||e);}
})();

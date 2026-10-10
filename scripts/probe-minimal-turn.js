(async function(){
const report=document.createElement('pre');report.id='wa-probe';report.hidden=true;document.body.append(report);let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};
try {
 await rendererLoaded;for(let i=0;i<200&&!transcriptReady;i++)await new Promise(r=>setTimeout(r,10));check(transcriptReady,'startup ready');
 for(let i=1;i<10000;i++){clearTimeout(i);clearInterval(i);}busy=true;observedRun=null;runBubble=null;clearStatus();transcript.replaceChildren();runStepState=null;runCounts=null;
 const snapshot=(extra={})=>({version:1,run_id:'minimal',model_calls:26,tool_calls:82,tokens_reported:12000,usage_calls:25,usage_unknown:0,pending_input:1000,context:{tokens:260000,capacity:1000000,estimated:true},...extra});
 runStartedAt=Date.now()-144000;handleEvent({type:'run_counts',counts:snapshot()});handleEvent({type:'status',text:'model'});runStepState.active.started=Date.now()-6000;updateRunElapsed();
 check(statusPhase.textContent==='6s'&&statusPhase.title==='Reasoning','only phase seconds; phase retained as tooltip');
 check(statusElapsed.textContent===' · ◈ ≥12k · ✧ 26 · ⚒ 82 · ◷ 2:24','requested spaced live strip with pending usage marked');
 handleEvent({type:'reasoning',text:'x'.repeat(40)});updateRunElapsed();check(turnTokenReadout()==='≥12k','text characters never fabricate exact billed tokens');
 handleEvent({type:'reasoning',text:'x'.repeat(200),complete:true});check(turnTokenReadout()==='≥12k','authoritative full copy never counts as usage');
 handleEvent({type:'run_counts',counts:snapshot({tokens_reported:13000,usage_calls:26,pending_input:null,context:{tokens:261000,capacity:1000000,estimated:false}})});
 check(turnTokenReadout()==='13k','reported usage replaces pending lower bound');
 check(chipModel.textContent==='▤ 26%/1M'&&composerModel.hidden&&!statusBtn.textContent.includes('fixture-model'),'context only, no model footer');
 handleEvent({type:'run_counts',counts:snapshot({tokens_reported:13000,usage_calls:26,usage_unknown:1})});check(turnTokenReadout()==='≥13k','unknown prior usage never invents a zero');
 const style=getComputedStyle(statusBtn);check(style.backgroundColor==='rgba(0, 0, 0, 0)'&&style.borderTopColor==='rgba(0, 0, 0, 0)'&&style.borderRadius==='5px','minimal trigger resting style');
 statusBtn.click();check(balloon.open,'minimal trigger still opens balloon');balloon.close();
 check(getComputedStyle(document.documentElement).getPropertyValue('--radius').trim()==='5px'&&getComputedStyle(input).borderRadius==='5px'&&getComputedStyle(sendButton).borderRadius==='5px','one global component radius');
 check(!document.querySelector('#steer,[data-action="steer"]'),'no main steer button');
 const child=document.createElement('wa-agent-session');document.body.append(child);child.task={subagent_id:'minimal-child',session_id:'minimal-child',state:'running',profile:'worker',model:'test-model'};
 check(!child.querySelector('[data-action="steer"]')&&!!child.querySelector('[data-action="cancel"]'),'child keeps cancel, not steer');child.remove();
 handleEvent({type:'commentary_delta',pending_id:'c1',text:'Checking '});const topic=streamedCommentaryBlock;
 check(topic.open&&topic.body.textContent==='Checking'&&topic.querySelector('.trace-meta').textContent==='9 chars'&&!topic.closest('wa-run'),'first commentary chunk already in open topic');
 handleEvent({type:'commentary_delta',pending_id:'c1',text:'the result.'});check(topic.querySelector('.trace-meta').textContent==='20 chars','header grows live');
 topic.toggle();check(!topic.open,'reader closes explicitly');
 handleEvent({type:'commentary',pending_id:'c1',message_id:'c1-id',text:'Checking the result.'});check(topic.isConnected&&!topic.open&&transcript.querySelectorAll('wa-commentary').length===1,'resolution keeps same topic and manual state');
 handleEvent({type:'commentary_delta',pending_id:'c2',text:'Verified.'});const second=streamedCommentaryBlock;
 handleEvent({type:'commentary',pending_id:'c2',message_id:'c2-id',text:'Verified.'});
 handleEvent({type:'tool',name:'read',call_id:'minimal-read',arguments:{path:'evidence'}});handleEvent({type:'tool_result',name:'read',result:{ok:true}});
 handleEvent({type:'final_answer_begin',message_id:'a1'});handleEvent({type:'delta',text:'The change is verified.'});handleEvent({type:'reply',message_id:'a1',text:'The change is verified.'});handleEvent({type:'done'});
 check(second.open&&!second.closest('wa-run')&&second.body.getBoundingClientRect().height>0,'commentary stays readable after final/run folding');
 const rows=[{seq:1,id:'minimal',role:'user',content:'Minimal chat',created_at:Date.now()/1000},{seq:2,id:'c1-id',role:'assistant',phase:'commentary',content:'Checking the result.'},{seq:3,id:'c2-id',role:'assistant',phase:'commentary',content:'Verified.'},{seq:4,id:'a1',role:'assistant',content:'The change is verified.'}];
 busy=false;repaintMessages(rows,{state:'answered',notify:false});check(!transcript.querySelector('[data-message-id="c1-id"]').open&&transcript.querySelector('[data-message-id="c2-id"]').open,'checkpoint repaint keeps explicit closure and open default');
 chatShell.warning.setNotice('transcript','transcript not loaded - retrying in 30s');setLiveness({working:false,kind:'worker',seconds:55});setLiveness({working:true});check(chatShell.warning.textContent.includes('retrying'),'healthy heartbeat cannot erase transcript warning');
 chatShell.warning.setNotice('active','no result is recorded yet. A run is in progress on the node; this page will check again when it becomes idle.');
 check(!transcript.contains(chatShell.warning)&&Math.abs(chatShell.warning.getBoundingClientRect().top-chatShell.getBoundingClientRect().top-5)<1,'shared warning is 5px below chat header, outside status/transcript');
 clearActiveRunNotice();check(chatShell.warning.textContent.includes('retrying')&&!chatShell.warning.textContent.includes('no result'),'warning causes clear independently');
 chatShell.warning.clearNotices();check(chatShell.warning.hidden,'recovery hides warning');
 const originalFetch=window.fetch;const originalSession=window.__fixtures.session;const originalHealth=window.__fixtures.health;
 window.fetch=async(url,opts)=>String(url).includes('session?id=') ? new Response(JSON.stringify({error:'fixture embedded module missing'}),{status:500}) : originalFetch(url,opts);
 busy=false;observedRun=null;controller=null;transcriptRetryAt=0;await restoreSession(chatSession);
 check(chatShell.warning.textContent.includes('fixture embedded module missing')&&!transcript.textContent.includes('transcript not loaded')&&!statusLabel?.textContent.includes('transcript'),'real transcript-read error routes only to warning');
 window.fetch=originalFetch;window.__fixtures.session={session:{id:chatSession},state:{state:'unfinished'},messages:rows.slice(0,1)};
 window.__fixtures.health={...originalHealth,node_threads:[{role:'runs',session:chatSession,run_id:'9909',age_ms:20}],runs:[{conversation:chatSession,run_id:'9909',state:'running'}]};
 await restoreSession(chatSession);check(chatShell.warning.textContent.includes('no result is recorded yet')&&!transcript.querySelector('.active-run-notice'),'real active unfinished read uses top warning');
 window.__fixtures.session=originalSession;window.__fixtures.health=originalHealth;observedRun=null;chatShell.warning.clearNotices();
 for(const width of [320,540,800]){document.getElementById('panel').style.width=width+'px';busy=true;runBubble=null;runCounts=null;clearStatus();runStepState=null;handleEvent({type:'run_counts',counts:snapshot()});handleEvent({type:'status',text:'model'});updateRunElapsed();check(statusLine.scrollWidth<=statusLine.clientWidth+1,'live strip fits '+width);clearStatus();}
 document.getElementById('panel').style.width='540px';busy=false;runBubble=null;runStepState=null;repaintMessages(rows,{state:'answered',notify:false});
 // Compact decimal units retain full reported integers in details, never char guesses.
 for(const [value,want] of [[9,'9'],[99,'99'],[999,'999'],[9900,'9.9k'],[99900,'99.9k'],[999900,'999.9k'],[999950,'1M'],[1138787,'1.1M'],[1543336,'1.5M'],[9000000,'9M']])check(formatTokens(value)===want,'compact units '+value);
 check(formatTokens(0)==='0'&&formatTokens(undefined)==='?','zero and unknown distinct in abbreviated usage');
 const contextValue=label=>Array.from(contextBox.querySelectorAll('span')).find(node=>node.textContent===label)?.nextElementSibling?.textContent;
 const oldSettings=settings;measuredContexts.delete(transcript);runCounts=null;busy=false;observedRun=null;
 check(formatContextCapacity(128000)==='0.128M'&&formatContextCapacity(1050000)==='1.05M','capacity decimal retains exact integer window');
 clearStatus();runBubble=null;runStepState=null;busy=true;handleEvent({type:'status',text:'model'});
 settings={...settings,model:'context-fixture',context_limit:1050000,observability:{available:true,session_id:chatSession,last_request:{model:'context-fixture'},last:{normalized:{prompt:436800}}}};
 updateContextReadouts();renderContext();
 check(chipModel.textContent==='▤ 42%/1.05M'&&contextValue('last measured input')==='436.8k'&&contextValue('selected capacity')==='1.05M'&&contextValue('occupancy')==='42%/1.05M','436800/1050000 aligns footer and balloon');
 check(chipModel.title.includes('436,800')&&chipModel.title.includes('1,050,000')&&contextBox.textContent.includes('41.6000%'),'raw exact counts and unclamped percentage visible for fine control');
 balloon.open=true;const first=contextBox.firstChild;updateContextReadouts();check(contextBox.firstChild===first,'unchanged context does not replace selected balloon text');
 runCounts={...snapshot(),context:{tokens:900000,capacity:1050000,model:'context-fixture',estimated:true},scope:runStepScope()};updateContextReadouts();
 check(chipModel.textContent==='▤ 42%/1.05M'&&contextBox.textContent.includes('436.8k'),'pending text estimate never replaces measured context');
 handleEvent({type:'run_counts',counts:snapshot({tokens_reported:1138787,model_calls:26,usage_calls:26,pending_input:null,context:{tokens:500000,capacity:1050000,estimated:false,model:'context-fixture'}})});
 check(chipModel.textContent==='▤ 48%/1.05M'&&contextValue('last measured input')==='500k'&&turnTokenReadout()==='1.1M','streamed provider snapshot updates both surfaces together');
 check(contextBox.textContent.includes('500,000')&&statusElapsed?.title?.includes('1,138,787'),'abbreviation retains exact raw turn/context details');
 handleEvent({type:'run_counts',counts:snapshot({tokens_reported:1138787,model_calls:27,usage_calls:26,context:{tokens:777777,capacity:1050000,estimated:true,model:'context-fixture'}})});
 check(chipModel.textContent==='▤ 48%/1.05M'&&turnTokenReadout()==='≥1.1M','next pending attempt keeps exact last measure and marks lower bound');
 // Settings capacity switches invalidate paint even if total token spend stays unchanged.
 busy=false;observedRun=null;settings={...settings,context_limit:2000000};renderMetadataParts();
 check(chipModel.textContent==='▤ 25%/2M'&&contextBox.textContent.includes('25%/2M'),'capacity setting invalidates both views immediately');
 acceptSettings({provider:settings.provider,model:settings.model,observability:{...settings.observability,last:{normalized:{prompt:600000}}}});renderMetadataParts();
 check(chipModel.textContent==='▤ 30%/2M'&&contextValue('last measured input')==='600k','fresh idle metadata supersedes older retained checkpoint');
 measuredContexts.delete(transcript);runCounts=null;settings={...settings,model:'different-model'};renderMetadataParts();
 check(chipModel.textContent==='▤ ??%/2M'&&contextBox.textContent.includes('unknown'),'model mismatch never divides foreign prompt by selected capacity');
 settings={...settings,model:'context-fixture',observability:{...settings.observability,last:{normalized:{prompt:0}}}};renderMetadataParts();
 check(chipModel.textContent==='▤ 00%/2M'&&contextBox.textContent.includes('0 tokens'),'measured zero is not unknown');
 settings={...settings,observability:{...settings.observability,session_id:'foreign-session',last:{normalized:{prompt:436800}}}};renderMetadataParts();
 check(chipModel.textContent==='▤ ??%/2M','foreign conversation metadata remains unknown');
 balloon.open=false;settings=oldSettings;runCounts=null;measuredContexts.delete(transcript);contextPaintKey='';
 // Shared attachment intake: cards acknowledge success; no run status/timer.
 clearStatus();busy=false;runBubble=null;runStepState=null;observedRun=null;runStatusTicker=null;
 chatShell.clearAttachments();input.value='draft';draftUndo=[];draftRedo=[];draftNow=snapshotDraft();
 const Reader=window.FileReader;
 window.FileReader=class {readAsDataURL(){this.result='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';queueMicrotask(()=>this.onload());}};
 const picture=new File(['fixture-image'],'pasted.png',{type:'image/png'}),note=new File(['note contents'],'notes.txt',{type:'text/plain'});
 try {
  const receipt=await addFiles([picture,note]);check(receipt.added===2&&!statusLine&&!runStatusTicker,'idle successful intake creates neither status nor timer');
  const cards=chatShell.attachmentsEl.children;check(cards.length===2&&cards[0].textContent==='×'&&cards[1].textContent==='▧×'&&!chatShell.attachmentsEl.querySelector('b'),'cards have no visible names/descriptions');
  for(const card of cards){const box=card.getBoundingClientRect(),remove=card.querySelector('button'),button=remove.getBoundingClientRect();
    check(Math.abs(box.width-box.height)<1&&box.width===55,'square card uses central size');
    check(button.right<=box.right+1&&button.top>=box.top&&button.right>box.right-3&&button.top<box.top+3,'remove at card top right');
    check(remove.getAttribute('aria-label').includes(card.title),'filename remains accessible on remove');
  }
  check(cards[0].querySelector('img').alt==='pasted.png'&&composedBody('draft').body.includes('pasted.png')&&composedText('draft').includes('[file: notes.txt]'),'preview and outgoing identity unchanged');
  cards[0].querySelector('button').click();check(attachments.length===1&&attachments[0].name==='notes.txt','remove deletes exact draft attachment');
  check(undoDraft()&&attachments.length===2&&attachments[0].name==='pasted.png','manual removal remains undoable');clearStatus();
  busy=true;runBubble=null;runStepState=null;runCounts=null;runStartedAt=Date.now();handleEvent({type:'status',text:'model'});
  const status=statusLine,statusText=statusLabel.textContent,phase=runStepState.active,clock=runStatusTicker;
  await addFiles([picture]);check(statusLine===status&&statusLabel.textContent===statusText&&runStepState.active===phase&&runStatusTicker===clock,'active intake cannot replace phase/status/clock');
  const pane=document.createElement('wa-agent-session');document.body.append(pane);pane.task={subagent_id:'attachment-child',session_id:'attachment-child',state:'running',profile:'worker'};
  const notice=pane.notice.textContent;await pane.collectFiles([picture]);
  check(pane.notice.textContent===notice&&pane.shell.attachmentsEl.children.length===1&&!pane.shell.attachmentsEl.textContent.includes('pasted.png'),'child successful intake uses only shared cards');
  await pane.collectFiles([new File(['x'],'bad.bmp',{type:'image/bmp'})]);check(pane.notice.textContent.includes('skipped'),'child refusal remains visible');
  pane.remove();await addFiles([new File(['x'],'bad.bmp',{type:'image/bmp'})]);check(statusLabel.textContent.includes('skipped'),'main refusal remains visible');
  clearStatus();busy=false;runBubble=null;runStepState=null;chatShell.clearAttachments();
  const promoted=document.createElement('wa-window');document.body.append(promoted);
  check(getComputedStyle(promoted.shadowRoot.querySelector('.frame')).borderRadius==='5px','promoted shadow frame inherits global radius');
  document.documentElement.style.setProperty('--radius','9px');
  check([input,sendButton,statusBtn,promoted.shadowRoot.querySelector('.frame')].every(node=>getComputedStyle(node).borderRadius==='9px'),'single token flips composer/status/promoted frame');
  document.documentElement.style.removeProperty('--radius');promoted.remove();
  let prevented=false;chatShell._paste({clipboardData:{items:[{kind:'file',getAsFile:()=>picture}]},preventDefault(){prevented=true;}});
  for(let i=0;i<12;i++)await Promise.resolve();
  check(prevented&&attachments.length===1&&!statusLine&&!runStatusTicker,'actual clipboard path stays quiet and renders its card');
  const pastedName=attachments[0].name;check(pastedName==='pasted.png','paste keeps outgoing file identity');
  chatShell.clearAttachments();await addFiles([picture,picture,picture]);check(!statusLine&&!runStatusTicker,'final preview intake stays quiet');
 } finally {window.FileReader=Reader;}
 // Remove fixture-only refusal bubbles before the representative screenshot.
 repaintMessages(rows,{state:'answered',notify:false});
 // Leave a representative live strip, open commentary and attachment squares for inspection.
 busy=true;runStartedAt=Date.now()-144000;runBubble=transcript.querySelector('wa-message[role="assistant"]');runStepState=null;
 settings={...settings,model:'context-fixture',context_limit:1050000};
 handleEvent({type:'run_counts',counts:snapshot({tokens_reported:1138787,context:{tokens:436800,capacity:1050000,model:'context-fixture',estimated:false}})});handleEvent({type:'status',text:'model'});runStepState.active.started=Date.now()-11000;updateRunElapsed();
 report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
} catch(error){report.dataset.status='fail';report.textContent=String(error.stack||error);}
})();

(async function(){
const report=document.createElement('pre');report.id='wa-probe';report.hidden=true;document.body.append(report);let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};
try {
 await rendererLoaded;for(let i=0;i<200&&!transcriptReady;i++)await new Promise(r=>setTimeout(r,10));check(transcriptReady,'startup ready');
 for(let i=1;i<10000;i++){clearTimeout(i);clearInterval(i);}busy=true;observedRun=null;runBubble=null;clearStatus();transcript.replaceChildren();runStepState=null;runCounts=null;
 const snapshot=(extra={})=>({version:1,run_id:'minimal',model_calls:26,tool_calls:82,tokens_reported:12000,usage_calls:25,usage_unknown:0,pending_input:1000,context:{tokens:260000,capacity:1000000,estimated:true},...extra});
 runStartedAt=Date.now()-144000;handleEvent({type:'run_counts',counts:snapshot()});handleEvent({type:'status',text:'model'});runStepState.active.started=Date.now()-6000;updateRunElapsed();
 check(statusPhase.textContent==='6s'&&statusPhase.title==='Reasoning','only phase seconds; phase retained as tooltip');
 check(statusElapsed.textContent==='|◈ ~13000|✧ 26|⚒ 82|◷ 2:24','requested live strip');
 handleEvent({type:'reasoning',text:'x'.repeat(40)});updateRunElapsed();check(turnTokenReadout()==='~13010'&&liveTokenChars===40,'live output estimate grows without claiming provider tokens');
 handleEvent({type:'reasoning',text:'x'.repeat(200),complete:true});check(liveTokenChars===40,'authoritative full copy not counted twice');
 handleEvent({type:'run_counts',counts:snapshot({tokens_reported:13000,usage_calls:26,pending_input:null,context:{tokens:261000,capacity:1000000,estimated:false}})});
 check(turnTokenReadout()==='13000'&&liveTokenChars===0,'reported usage replaces estimate');
 check(chipModel.textContent==='▤ 26%/1M'&&composerModel.hidden&&!statusBtn.textContent.includes('fixture-model'),'context only, no model footer');
 handleEvent({type:'run_counts',counts:snapshot({tokens_reported:13000,usage_calls:26,usage_unknown:1})});check(turnTokenReadout()==='≥13000','unknown prior usage never invents a zero');
 const style=getComputedStyle(statusBtn);check(style.backgroundColor==='rgba(0, 0, 0, 0)'&&style.borderTopColor==='rgba(0, 0, 0, 0)'&&style.borderRadius==='3px','minimal trigger resting style');
 statusBtn.click();check(balloon.open,'minimal trigger still opens balloon');balloon.close();
 check(getComputedStyle(document.documentElement).getPropertyValue('--radius').trim()==='3px'&&getComputedStyle(input).borderRadius==='3px'&&getComputedStyle(sendButton).borderRadius==='3px','one global component radius');
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
 // Leave a representative live strip and open commentary for visual inspection.
 busy=true;runStartedAt=Date.now()-144000;runBubble=transcript.querySelector('wa-message[role="assistant"]');runStepState=null;
 handleEvent({type:'run_counts',counts:snapshot()});handleEvent({type:'status',text:'model'});runStepState.active.started=Date.now()-6000;updateRunElapsed();
 report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
} catch(error){report.dataset.status='fail';report.textContent=String(error.stack||error);}
})();

(async()=>{const report=document.createElement('pre');report.id='wa-probe';report.hidden=true;document.body.append(report);let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};
try{await rendererLoaded;for(let i=0;i<200&&!transcriptReady;i++)await new Promise(r=>setTimeout(r,10));check(transcriptReady,'startup');for(let i=1;i<10000;i++){clearTimeout(i);clearInterval(i);}busy=false;observedRun=null;clearStatus();runBubble=null;runStepState=null;runCounts=null;transcript.replaceChildren();
 const now=Date.now(),growth=(current,extra={})=>({version:1,known:true,baseline:600000,current,added:current-600000,partial:false,pending:false,complete:true,compactions:0,...extra}),snapshot=(g,extra={})=>({kind:'run_counts',version:1,run_id:'growth-turn',model_calls:4,tool_calls:3,tokens_reported:3500000,usage_calls:4,usage_unknown:0,context_growth:g,complete:true,elapsed_ms:45000,...extra});
 const user={id:'growth-turn',seq:1,role:'user',content:'Grow context from600k to850k',created_at:(now-45000)/1000,trace:[snapshot(growth(600000),{model_calls:0,tool_calls:0,tokens_reported:0,usage_calls:0,complete:false})]},answer={id:'growth-answer',seq:2,role:'assistant',content:'Added250k to context.',created_at:now/1000,trace:[snapshot(growth(850000))]};
 repaintMessages([user,answer],{state:'answered',notify:false});const footer=transcript.querySelector('.finished .chat-content-run-elapsed');
 // WHY (operator, 2026-10-05): the stats line is compact - glyph glued to value, one space between
 // pairs - and the pairs now run model calls, tool calls, tokens, total duration (`👣4 ⚒3 ◈250k
 // ◷0:45`). Same property as before: the measured token delta is stated in full beside the run's
 // model/tool/time totals; only its place in the line moved.
 check(footer.textContent==='👣4 ⚒3 ◈250k ◷0:45','completed line states the token delta beside model/tool/time totals');
 check(footer.title.includes('250,000')&&footer.title.includes('600,000 → 850,000')&&!footer.textContent.includes('3.5M'),'raw delta endpoints available; cache reread/billed totals excluded');
 repaintMessages([user,answer],{state:'answered',notify:false});check(transcript.querySelector('.finished .chat-content-run-elapsed').textContent===footer.textContent,'reload stable tokens without summing snapshots');
 const child=document.createElement('wa-agent-session');document.body.append(child);child.task={session_id:'growth-child',subagent_id:'growth-child',state:'completed',settled:true,model:'test',profile:'worker'};
 paintChildTranscript(child.transcript,[user,{...answer,trace:[snapshot(growth(850000),{run_id:'child-growth'})]}],{task:child.task,state:'answered',notify:false});
 // WHY (operator, 2026-10-05): compact form - the child's terminal footer is the same glued line in
 // the same order (`👣4 ⚒3 ◈250k ◷0:45`); one line shape, not two.
 check(child.statusLine.textContent.includes('👣4 ⚒3 ◈250k ◷0:45'),'child terminal exact same pairs in the same order');check(runCounts.run_id==='growth-turn','child cannot overwrite parent baseline');child.remove();
 // WHY (operator, 2026-10-05): compact form - an old billed-only snapshot still has no measured
 // boundary, and the compact line still says so as `◈~?` (estimate, not measured) rather than a bare
 // `◈ ?`. It is no longer the FIRST pair (the row leads with the model calls), so the pair is looked
 // for rather than required at the front: the mark's meaning is the property under test.
 repaintMessages([user,{...answer,trace:[snapshot(null)]}],{state:'answered',notify:false});check(transcript.querySelector('.finished .chat-content-run-elapsed').textContent.includes(' ◈~? '),'old billed-only snapshots remainunknown');
 repaintMessages([user,{...answer,trace:[snapshot({...growth(850000),known:false,added:null})]}],{state:'answered',notify:false});check(turnTokenReadout()==='?','unknown baseline not fabricated');
 repaintMessages([user,{...answer,trace:[snapshot({...growth(850000),added:3500000})]}],{state:'answered',notify:false});check(turnTokenReadout()==='?','contradictory snapshot cannot pretend cached bill is growth');
 repaintMessages([user,{...answer,trace:[snapshot(growth(200000,{compactions:1}))]}],{state:'answered',notify:false});check(turnTokenReadout()==='-400k'&&transcript.querySelector('.finished .chat-content-run-elapsed').title.includes('compaction'),'net compaction shrink signed and described');
 repaintMessages([user,{...answer,trace:[snapshot(growth(850000,{partial:true}))]}],{state:'failed',notify:false});check(turnTokenReadout()==='~250k','missing end/failure incomplete notfalse exact');
 busy=true;runBubble=null;runStepState=null;clearStatus();runCounts=null;observedRun=null;runStartedAt=now-45000;
 handleEvent({type:'run_counts',counts:snapshot(growth(620000,{pending:true,complete:false}),{model_calls:4,usage_calls:3,complete:false})});handleEvent({type:'status',text:'model'});
 // WHY (operator, 2026-10-05): compact form - the live row is the same glued line, `~` kept as the
 // one pending mark. The live row splits its one line around the clock (model calls before it,
 // tools/tokens/duration after), so the tool pair begins the second half.
 check(statusElapsed.textContent.includes('⚒3 ◈~20k ◷0:45')&&statusCalls.textContent.includes('👣4·'),'live partial boundary with pending mark');
 handleEvent({type:'reasoning',text:'not tokens'.repeat(100)});check(turnTokenReadout()==='~20k','visible char deltas neverbilled or accumulated');
 handleEvent({type:'run_counts',counts:snapshot(growth(850000))});check(turnTokenReadout()==='250k','measured live endpoint updates');
 handleEvent({type:'run_counts',counts:snapshot(growth(850000))});check(turnTokenReadout()==='250k','duplicate snapshot noadd');
 handleEvent({type:'reply',text:'Added250k.',message_id:'live-growth'});handleEvent({type:'done'});busy=false;
 check(transcript.querySelectorAll('.finished .chat-content-run-elapsed').length>=1,'live completed retains tokenprefix');
 for(const width of [320,540,800]){document.getElementById('panel').style.width=width+'px';for(const line of transcript.querySelectorAll('.finished'))check(line.scrollWidth<=line.clientWidth+1,'terminal prefixfits'+width);}
 document.getElementById('panel').style.width='540px';runBubble=null;runStepState=null;repaintMessages([user,answer],{state:'answered',notify:false});
 report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
}catch(error){report.dataset.status='fail';report.textContent=String(error.stack||error);}})();

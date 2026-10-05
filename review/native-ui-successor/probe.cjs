// Frozen original genuine-native instrument, extended in the review lane only.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const repo=path.resolve(__dirname,'../..'),original='18bc6bf05be9cdbd01a1e50a6a520e0e9e9a499b';
const raw=spawnSync('git',['show',original+':scripts/test-native-child-browser.cjs'],{cwd:repo,encoding:'utf8',windowsHide:true});assert.equal(raw.status,0,raw.stderr);
let source=raw.stdout;
function replace(from,to){assert.ok(source.includes(from),'immutable fixture anchor absent: '+from);source=source.replace(from,to);}
replace("const repo=path.resolve(__dirname,'..');",`const repo=${JSON.stringify(repo)};`);
replace("WASM_AGENT_LUA_ROOT:repo", "WASM_AGENT_LUA_ROOT:(process.argv.includes('--lua-root')?path.resolve(process.argv[process.argv.indexOf('--lua-root')+1]):repo)");
replace('const pages=[];',`const pages=[];
function review(value,label,details=null){report.review ||= {cases:[],failures:[]};report.review.cases.push({label,passed:!!value,details});if(!value)report.review.failures.push(label);}
`);
replace("check((await api('subagents',{...binding,after:9007199254740990})).error==='native_event_cursor_out_of_range','native refuses future cursor');",`
  check((await api('subagents',{...binding,after:9007199254740990})).error==='native_event_cursor_out_of_range','native refuses future cursor');
  for(const after of ${JSON.stringify(require('./cursor-cases.json').invalid)}){
    const response=await api('subagents',{...binding,after});review(response.error==='invalid_native_event_cursor','malformed cursor named refusal '+JSON.stringify(after),{error:response.error,ok:response.ok,next:response.next_seq});
  }
  for(const after of [undefined,0,'0']){
    const response=await api('subagents',{...binding,...(after===undefined?{}:{after})});
    review(response.ok===true&&JSON.stringify(response.events)===JSON.stringify(live.events),'absent/initial cursor compatibility '+String(after));
  }
  for(const after of [live.next_seq,String(live.next_seq)]){
    const response=await api('subagents',{...binding,after});review(response.ok===true&&JSON.stringify(response.events)===JSON.stringify(tail.events),'exact delivered cursor compatibility '+typeof after);
  }
`);
replace("const original='NATIVE-B-COMPLETE'+('原'.repeat(16000));",`
  // Freeze observer polling only; the genuine provider/native child continues independently.
  await evaluate(nativePage,"window.reviewRetained=document.createElement('wa-agent-session');reviewRetained.style.cssText='position:fixed;inset:0;width:600px;height:700px;z-index:9999;background:var(--panel)';document.body.append(reviewRetained);reviewRetained.task="+JSON.stringify(nativeChild)+';refreshAgentPane(reviewRetained).then(()=>{runPolling=true;reviewRetained.input.value="REVIEW-PERSISTENT-DRAFT";return true;})');
  await evaluate(nativePage,"window.reviewRaw=reviewRetained.transcript.querySelector('[data-live-channel=delta]');window.reviewMainRaw=messages.querySelector('[data-live-channel=delta]');window.reviewTrace=reviewRetained.transcript.querySelector('wa-trace');reviewTrace.open=false;reviewRetained.transcript.scrollTop+=reviewRaw.getBoundingClientRect().top-reviewRetained.transcript.getBoundingClientRect().top+30;true");
  const liveBefore=await evaluate(nativePage,"({main:messages.textContent,pane:reviewRetained.transcript.textContent,place:transcriptPlace(reviewRetained.transcript),keys:[...reviewRetained.transcript.querySelectorAll('[data-ledger-key]')].map(e=>e.dataset.ledgerKey)})");
  const reviewJournal=path.join(root,'.wasm-agent','subagents',receipt.subagent_id,'events.sqlite');
  fs.renameSync(reviewJournal,reviewJournal+'.review-preserved');
  try{
    await evaluate(nativePage,'syncNativeSession(chatSession,conversationEpoch,activeNode).then(()=>refreshAgentPane(reviewRetained)).then(()=>true)');
    const heldView=await evaluate(nativePage,"({main:messages.textContent,pane:reviewRetained.transcript.textContent,notice:reviewRetained.notice.textContent,status:document.body.innerText,draft:reviewRetained.input.value,place:transcriptPlace(reviewRetained.transcript),keys:[...reviewRetained.transcript.querySelectorAll('[data-ledger-key]')].map(e=>e.dataset.ledgerKey)})");
    review(heldView.main.includes('raw-299')&&heldView.pane.includes('raw-299'),'unavailable live journal preserves known raw text',heldView);
    review(heldView.main.includes('LIVE-REASONING START')&&heldView.pane.includes('LIVE-REASONING START'),'unavailable live journal preserves known typed reasoning');
    review(heldView.notice.includes('native_event_evidence_unavailable')&&heldView.status.includes('native_event_evidence_unavailable'),'unavailable live journal gap stays visibly named');
    review(heldView.draft==='REVIEW-PERSISTENT-DRAFT','unavailable live journal keeps draft');
    review(liveBefore.keys.every(key=>heldView.keys.includes(key)),'unavailable live journal keeps known projection identities');
    review(heldView.place.key===liveBefore.place.key&&Math.abs(heldView.place.offset-liveBefore.place.offset)<=1,'unavailable live journal keeps stable reader anchor');
  }finally{fs.renameSync(reviewJournal+'.review-preserved',reviewJournal);}
  await evaluate(nativePage,'syncNativeSession(chatSession,conversationEpoch,activeNode).then(()=>refreshAgentPane(reviewRetained)).then(()=>true)');
  review(await evaluate(nativePage,"messages.textContent.split('LIVE-B').length===2&&reviewRetained.transcript.textContent.split('LIVE-B').length===2&&reviewRetained.transcript.textContent.includes('raw-299')"),'restored live journal known output exactly once');
  const original='NATIVE-B-COMPLETE'+('原'.repeat(16000));
`);
replace("check((await api('health')).subagents.active===0,'all native child threads settled before scratch retirement');",`
  check((await api('health')).subagents.active===0,'all native child threads settled before scratch retirement');
  const terminalTask=await api('subagents',{action:'status',id:receipt.subagent_id});
  const modelCount=report.models.length;
  const terminalPage=await api('subagents',{action:'session',id:receipt.subagent_id,limit:200,byte_limit:4096});
  const terminalReference=terminalPage.messages.find(row=>row.omitted&&row.role==='assistant');
  assert.ok(terminalReference,'fixture requires real oversized terminal evidence');
  let byteAfter=1,fullVersion=null,fullEncoded='';
  for(;;){const part=await api('subagents',{action:'session',id:receipt.subagent_id,message_id:terminalReference.id,byte_offset:byteAfter,byte_limit:4096,...(fullVersion?{message_version:fullVersion}:{})});
    assert.ok(part.next_offset>byteAfter&&(!fullVersion||fullVersion===part.message_version));fullVersion=part.message_version;fullEncoded+=part.content;byteAfter=part.next_offset;if(part.eof)break;}
  const terminalOriginal=JSON.parse(fullEncoded);
  fs.renameSync(reviewJournal,reviewJournal+'.review-preserved');
  try{
    await evaluate(nativePage,'reviewRetained.task='+JSON.stringify(terminalTask)+';syncNativeSession(chatSession,conversationEpoch,activeNode).then(()=>refreshAgentPane(reviewRetained)).then(()=>true)');
    const terminalView=await evaluate(nativePage,"({main:messages.textContent,pane:reviewRetained.transcript.textContent,notice:reviewRetained.notice.textContent,status:document.body.innerText,draft:reviewRetained.input.value,mainKeys:[...messages.querySelectorAll('[data-ledger-key]')].map(e=>e.dataset.ledgerKey),paneKeys:[...reviewRetained.transcript.querySelectorAll('[data-ledger-key]')].map(e=>e.dataset.ledgerKey)})");
    report.review.terminal=terminalView;
    review(terminalView.main.includes('NATIVE-B-COMPLETE')&&terminalView.pane.includes('NATIVE-B-COMPLETE'),'unavailable terminal journal existing main and pane show durable answer');
    review(terminalView.main.split('NATIVE-B-COMPLETE').length===2&&terminalView.pane.split('NATIVE-B-COMPLETE').length===2,'unavailable terminal journal answer exactly once');
    review(terminalView.pane.includes('raw-299')&&terminalView.main.includes('raw-299'),'terminal fallback retains original delta-derived content');
    review(terminalView.notice.includes('native_event_evidence_unavailable')&&terminalView.status.includes('native_event_evidence_unavailable'),'terminal fallback does not hide native raw evidence gap');
    review(terminalView.draft==='REVIEW-PERSISTENT-DRAFT','terminal fallback retains draft');
    review(await evaluate(nativePage,"reviewRaw.isConnected&&reviewMainRaw.isConnected&&reviewTrace.open===false"),'terminal fallback preserves original raw DOM and folds');
    const terminalPlace=await evaluate(nativePage,'transcriptPlace(reviewRetained.transcript)');
    review(terminalPlace.key===liveBefore.place.key&&Math.abs(terminalPlace.offset-liveBefore.place.offset)<=1,'terminal fallback retains original raw scroll anchor',terminalPlace);
    const storedBodies=await evaluate(nativePage,"[...reviewRetained.transcript.querySelectorAll('[data-source=stored-session] .seg')].map(e=>e.rawText)");
    review(storedBodies.includes(terminalOriginal.content),'stored terminal fallback contains every original byte without clipping',{originalBytes:Buffer.byteLength(terminalOriginal.content),storedBytes:storedBodies.map(text=>Buffer.byteLength(text||''))});
    review(await evaluate(nativePage,"[...messages.querySelectorAll('[data-source=stored-session] .seg')].some(e=>e.rawText==="+JSON.stringify(terminalOriginal.content)+")"),'main stored terminal fallback contains complete original content');
    await evaluate(nativePage,"window.reviewFresh=document.createElement('wa-agent-session');document.body.append(reviewFresh);reviewFresh.task="+JSON.stringify(terminalTask)+';refreshAgentPane(reviewFresh).then(()=>true)');
    review(await evaluate(nativePage,"reviewFresh.transcript.textContent.includes('NATIVE-B-COMPLETE')&&reviewFresh.notice.textContent.includes('native_event_evidence_unavailable')"),'fresh terminal fallback shows durable answer and gap');
    for(let i=0;i<2;i++)await evaluate(nativePage,'syncNativeSession(chatSession,conversationEpoch,activeNode).then(()=>refreshAgentPane(reviewRetained)).then(()=>true)');
    review(await evaluate(nativePage,"messages.textContent.split('NATIVE-B-COMPLETE').length===2&&reviewRetained.transcript.textContent.split('NATIVE-B-COMPLETE').length===2&&reviewRetained.input.value==='REVIEW-PERSISTENT-DRAFT'"),'repeated unavailable terminal fallback is idempotent');
    for(const field of ['session_id','attempt_id','node_id','event_node_id','event_epoch']){
      const changed={...terminalTask,[field]:'foreign-review-'+field};
      await evaluate(nativePage,"window.reviewWrong=document.createElement('wa-agent-session');document.body.append(reviewWrong);reviewWrong.task="+JSON.stringify(changed)+';refreshAgentPane(reviewWrong).then(()=>true)');
      const wrong=await evaluate(nativePage,"({leaked:reviewWrong.transcript.textContent.includes('NATIVE-B-COMPLETE'),notice:reviewWrong.notice.textContent})");
      review(!wrong.leaked,'wrong '+field+' cannot unlock terminal fallback',wrong);
      await evaluate(nativePage,'reviewWrong.remove();true');
    }
    const beforeForeign=await evaluate(nativePage,'reviewRetained.transcript.textContent');
    await evaluate(nativePage,'(async()=>{const previous=session;session='+JSON.stringify(login.session)+';try{await refreshAgentPane(reviewRetained);}finally{session=previous;}return true;})()');
    review(await evaluate(nativePage,'reviewRetained.transcript.textContent')===beforeForeign,'foreign owner cannot replace confirmed terminal pane');
    const directForeign=await api('subagents',{action:'session',id:receipt.subagent_id,owner_user:nativeChild.owner_user},login.session);
    review(directForeign.error==='forbidden_subagent'&&!JSON.stringify(directForeign).includes('NATIVE-B-COMPLETE'),'foreign body owner cannot read fallback ledger');
    review((await api('subagents',{action:'session',id:receipt.subagent_id},'unknown-review-token')).status===401,'invalid credential cannot read fallback ledger');
    for(const field of ['session','chatSession','activeNode','conversationEpoch']){
      const mutation=field==='conversationEpoch'?'conversationEpoch++':field+"='foreign-review'";
      const expression="(async()=>{const before=messages.textContent,previous="+field+";const pending=syncNativeSession(chatSession,conversationEpoch,activeNode);"+mutation+";try{await pending;return messages.textContent===before;}finally{"+field+"=previous;}})()";
      review(await evaluate(nativePage,expression),'late unavailable fallback cannot cross main '+field);
    }
    for(const field of ['session_id','subagent_id','attempt_id']){
      const expression="(async()=>{const before=reviewRetained.transcript.textContent,previous=reviewRetained.task;const pending=refreshAgentPane(reviewRetained);reviewRetained.task={...previous,"+field+":'foreign-review'};try{await pending;return reviewRetained.transcript.textContent===before;}finally{reviewRetained.task=previous;}})()";
      review(await evaluate(nativePage,expression),'late unavailable fallback cannot cross pane '+field);
    }
    await evaluate(nativePage,'reviewFresh.remove();true');
  }finally{fs.renameSync(reviewJournal+'.review-preserved',reviewJournal);}
  const restored=await api('subagents',{...binding,archive:true});
  review(JSON.stringify(restored.events)===JSON.stringify(archive.events),'restored original first archive page identity and content unchanged');
  await evaluate(nativePage,'syncNativeSession(chatSession,conversationEpoch,activeNode).then(()=>refreshAgentPane(reviewRetained)).then(()=>true)');
  review(await evaluate(nativePage,"messages.textContent.split('NATIVE-B-COMPLETE').length===2&&reviewRetained.transcript.textContent.split('NATIVE-B-COMPLETE').length===2&&reviewRetained.transcript.textContent.includes('raw-299')"),'restored terminal journal does not duplicate or lose original rows');
  review(await evaluate(nativePage,"!reviewRetained.notice.textContent.includes('native_event_evidence_unavailable')"),'restored terminal journal clears gap only after successful attachment');
  review(report.models.length===modelCount,'fallback and restoration never replay inference');
  await evaluate(nativePage,'reviewRetained.remove();runPolling=false;true');
`);
replace('report.passed=true;',`report.passed=report.review.failures.length===0;
  if(!report.passed){report.error='review matrix failures: '+report.review.failures.join('; ');process.exitCode=1;console.error(report.error);}`);
const temporary=path.join(__dirname,'generated-probe.cjs');fs.writeFileSync(temporary,source);
const syntax=spawnSync(process.execPath,['--check',temporary],{encoding:'utf8',windowsHide:true});assert.equal(syntax.status,0,syntax.stderr);
if(process.argv.includes('--prepare-only')){fs.unlinkSync(temporary);console.log('Immutable-original connected review matrix generated and syntax checked; no processes or inference launched');}
else require(temporary);

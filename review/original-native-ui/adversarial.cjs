// Review-only extension of the exact producer fixture; product bytes remain unchanged.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const repo=path.resolve(__dirname,'../..');
let source=fs.readFileSync(path.join(repo,'scripts/test-native-child-browser.cjs'),'utf8');
function replace(from,to){assert.ok(source.includes(from),'fixture anchor absent: '+from);source=source.replace(from,to);}
replace("const repo=path.resolve(__dirname,'..');",`const repo=${JSON.stringify(repo)};`);
replace("await evaluate(nativePage,'nativeShowroom.remove();nativePane.remove();true');","await evaluate(nativePage,'nativeShowroom.remove();true');");
replace("const original='NATIVE-B-COMPLETE'+('原'.repeat(16000));",`await evaluate(nativePage,"window.reviewRetained=document.createElement('wa-agent-session');document.body.append(reviewRetained);reviewRetained.task="+JSON.stringify(nativeChild)+';refreshAgentPane(reviewRetained).then(()=>{runPolling=true;return true;})');
  const original='NATIVE-B-COMPLETE'+('原'.repeat(16000));`);
replace("check((await api('subagents',{...binding,after:9007199254740990})).error==='native_event_cursor_out_of_range','native refuses future cursor');","check((await api('subagents',{...binding,after:9007199254740990})).error==='native_event_cursor_out_of_range','native refuses future cursor');\n"+`
  report.review={cursor:[],fallback:{}};
  for(const after of ['garbage',{},true,-1,0.5,'9007199254740993']){
    const response=await api('subagents',{...binding,after});
    report.review.cursor.push({after,error:response.error||null,accepted:response.ok===true,next:response.next_seq});
  }
  check((await api('subagents',{...binding,owner_user:nativeChild.owner_user},login.session)).error==='forbidden_subagent','review forged body owner cannot grant evidence');
  check((await api('subagents',binding,'unknown-review-token')).status===401,'review invalid credential refused before native evidence');
`);
replace("check((await api('health')).subagents.active===0,'all native child threads settled before scratch retirement');",`
  check((await api('health')).subagents.active===0,'all native child threads settled before scratch retirement');
  const originalJournal=path.join(root,'.wasm-agent','subagents',receipt.subagent_id,'events.sqlite');
  fs.renameSync(originalJournal,originalJournal+'.review-preserved');
  try {
    const terminalTask=await api('subagents',{action:'status',id:receipt.subagent_id});
    report.review.fallback.terminalState=terminalTask.state;
    report.review.fallback.mainBefore=await evaluate(nativePage,"messages.textContent.includes('NATIVE-B-COMPLETE')");
    await evaluate(nativePage,'syncNativeSession(chatSession,conversationEpoch,activeNode).then(()=>true)');
    report.review.fallback.mainAfter=await evaluate(nativePage,"messages.textContent.includes('NATIVE-B-COMPLETE')");
    report.review.fallback.mainStatus=await evaluate(nativePage,'document.body.innerText');
    await evaluate(nativePage,'reviewRetained.task='+JSON.stringify(terminalTask)+';refreshAgentPane(reviewRetained).then(()=>true)');
    report.review.fallback.pane=await evaluate(nativePage,"({terminal:reviewRetained.transcript.textContent.includes('NATIVE-B-COMPLETE'),notice:reviewRetained.notice.textContent,text:reviewRetained.transcript.textContent})");
    // Fresh mount is the producer's existing fallback assertion; compare the same terminal here.
    await evaluate(nativePage,"window.reviewFresh=document.createElement('wa-agent-session');document.body.append(reviewFresh);reviewFresh.task="+JSON.stringify(terminalTask)+';refreshAgentPane(reviewFresh).then(()=>true)');
    report.review.fallback.fresh=await evaluate(nativePage,"({terminal:reviewFresh.transcript.textContent.includes('NATIVE-B-COMPLETE'),notice:reviewFresh.notice.textContent})");
    await evaluate(nativePage,'reviewFresh.remove();reviewRetained.remove();true');
  }finally{fs.renameSync(originalJournal+'.review-preserved',originalJournal);await evaluate(nativePage,'runPolling=false;true');}
`);
const temporary=path.join(__dirname,'generated-adversarial.cjs');
fs.writeFileSync(temporary,source);
require(temporary);

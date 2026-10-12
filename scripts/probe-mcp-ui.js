(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.hidden=true;document.body.append(report);
 let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};const tick=async()=>{for(let n=0;n<20;n++)await Promise.resolve();};
 try{
  await rendererLoaded;for(let n=0;n<200&&!transcriptReady;n++)await new Promise(resolve=>setTimeout(resolve,10));check(transcriptReady,'UI startup');
  for(let n=1;n<10000;n++){clearTimeout(n);clearInterval(n);}const originalFetch=window.fetch;const calls=[];let replies=[],controlResolve;
  const response=data=>({ok:true,status:200,json:async()=>data});
  window.fetch=(url,options={})=>{
   if(String(url)!=='mcp')return originalFetch(url,options);calls.push({method:options.method||'GET',headers:options.headers,body:options.body});
   const item=replies.shift();if(typeof item==='function')return item(options);return Promise.resolve(response(item||{ok:true,revision:1,servers:[],templates:{}}));
  };
  busy=true;const box=document.getElementById('mcp-box'),panel=box.querySelector('wa-mcps');box.hidden=false;
  const scope=mcpScope(),fixture={ok:true,revision:2,adapters:[{name:'WhatsApp',capabilities:['snapshot reads','media'],note:'Jobs own wakes'}],servers:[{id:'fixture',name:'Fixture <img onerror=attack>',definition:{transport:'stdio',tools:{echo:'read'}},enabled:false,probe:{ok:true,tools:[{name:'echo',description:'<script>attack</script>'}]},observed_status:'last probe passed'}],templates:{whatsapp:{id:'whatsapp',transport:'stdio',program:'node',args:['mcp-whatsapp.mjs'],tools:{read_snapshot:'read'}}}};
  let resolveFirst;replies.push(()=>new Promise(resolve=>resolveFirst=resolve));loadTopic('mcp-box');await tick();const second=refreshMcps();await tick();check(calls.length===1,'busy main does not queue MCP inventory and independent reads coalesce');
  resolveFirst(response(fixture));await second;check(panel.list.textContent.includes('Fixture'),'configured MCP inventory rendered');check(panel.list.textContent.includes('built-in profile-managed MCP'),'built-in WhatsApp displayed separately');check(!panel.list.querySelector('img,script'),'connector metadata rendered as text');check(calls.every(call=>call.method==='GET'),'opening never probes/connects/sends');
  panel.editor.value='draft survives failed read';replies.push(()=>Promise.reject(Error('read fixture failure')));await refreshMcps();check(panel.list.textContent.includes('Fixture')&&panel.editor.value==='draft survives failed read','failed read retains inventory and editor');check(panel.notice.textContent.includes('Refresh to retry'),'visible explicit retry');
  panel.template.click();check(JSON.parse(panel.editor.value).id==='whatsapp','template loads disabled local definition');
  panel.editor.value='not JSON';const before=calls.length;panel.save.click();await tick();check(calls.length===before&&panel.notice.textContent.includes('Invalid JSON'),'invalid editor cannot start a request');
  panel.editor.value=JSON.stringify(fixture.templates.whatsapp);replies.push(()=>new Promise(resolve=>controlResolve=resolve));panel.save.click();panel.save.click();await tick();check(calls.filter(call=>call.method==='POST').length===1,'mutating controls are single flight');
  const posted=JSON.parse(calls.at(-1).body);check(posted.action==='put'&&posted.expected_revision===2,'save uses captured registry revision, never implies enable');check(panel.save.disabled,'pending control cannot paint successful change');
  replies.push({...fixture,revision:3});controlResolve(response({ok:true,enabled:false}));await tick();check(!panel.save.disabled&&panel.data.revision===3,'persistent response and fresh inventory settle control');
  panel.editor.value='node A draft';const oldNode=activeNode;activeNode='mcp-private-node-B';replies.push({ok:true,revision:8,servers:[],templates:{}});await refreshMcps();check(panel.list.textContent.includes('No MCPs configured')&&!panel.list.textContent.includes('Fixture'),'node/account change clears foreign inventory');check(panel.editor.value==='','draft is scope specific');
  panel.editor.value='node B draft';activeNode=oldNode;replies.push(fixture);await refreshMcps();check(panel.editor.value==='node A draft','return restores the right node draft');
  let stale;replies.push(()=>new Promise(resolve=>stale=resolve));const pending=refreshMcps();await tick();activeNode='mcp-private-node-B';replies.push({ok:true,revision:9,servers:[],templates:{}});await refreshMcps();stale(response({...fixture,revision:100}));await pending;check(panel.data.revision===9,'delayed foreign-scope result ignored');
  activeNode=oldNode;replies.push(fixture);await refreshMcps();
  const child=document.createElement('wa-agent-session');document.body.append(child);child.task={session_id:'mcp-child',subagent_id:'mcp-child',state:'running',settled:false};child.input.value='child draft';
  replies.push(fixture);await refreshMcps();check(child.input.value==='child draft'&&calls.at(-1).method==='GET','child activity/draft unaffected by inventory');child.remove();
  replies.push(()=>Promise.reject(Error('lost control response')));const enable=[...panel.list.querySelectorAll('button')].find(button=>button.textContent==='Enable approved tools');enable.click();await tick();check(panel.notice.textContent.includes('never replay automatically'),'failed/ambiguous control stays explicit');check(calls.filter(call=>call.method==='POST').length===2,'no automatic effect replay');
  panel.inventory={...fixture,servers:[{...fixture.servers[0],probe:{ok:false,error:'connection refused'}}]};panel.busy=true;panel.busy=false;check([...panel.list.querySelectorAll('button')].find(button=>button.textContent==='Enable approved tools').disabled,'failed probe cannot be enabled after pending resets');
  check(panel.list.textContent.includes('Probe failed: connection refused'),'durable probe error displayed');
  document.getElementById('panel').style.width='540px';busy=false;window.fetch=originalFetch;
  setEngine(true);box.hidden=false;box.closest('.engine-topic').scrollIntoView({block:'start'});check(document.body.classList.contains('engine'),'actual Engine mode for visual proof');
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(error){report.dataset.status='fail';report.textContent=String(error.stack||error);}
})();

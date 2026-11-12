// The window's `/mcp`, asserted against the panel that ships: one row per connector with where it runs,
// its transport, its state and how many tools the model is given; opened, the exact callable names (verbatim,
// underscores intact), their descriptions and their input schemas; a toggle that carries the revision the row
// was drawn from; a read-only window that cannot toggle; a peer whose registry was not reported offering no
// control; an older node named instead of shown as empty. Plus the invariants the panel always had: opening
// probes nothing, controls are single flight, a failed read retains what it had, and a refusal is reported as
// a decision while an unknown outcome is never replayed. Fixture-only: no server starts and no node is called.
(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.hidden=true;document.body.append(report);
 let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};const tick=async()=>{for(let n=0;n<20;n++)await Promise.resolve();};
 // A control answers through fetch, then reloads the inventory: wait for the state the panel settles into
 // instead of counting microtask ticks, which is how a check reads the frame before the answer lands.
 const until=async(test,label)=>{for(let n=0;n<400;n++){if(test())return;await new Promise(resolve=>setTimeout(resolve,5));}throw Error('timed out: '+label);};
 try{
  await rendererLoaded;for(let n=0;n<200&&!transcriptReady;n++)await new Promise(resolve=>setTimeout(resolve,10));check(transcriptReady,'UI startup');
  for(let n=1;n<10000;n++){clearTimeout(n);clearInterval(n);}const originalFetch=window.fetch;const calls=[];let replies=[],controlResolve;
  const response=data=>({ok:true,status:200,json:async()=>data});
  const posts=()=>calls.filter(call=>call.method==='POST');
  window.fetch=(url,options={})=>{
   if(String(url)!=='mcp')return originalFetch(url,options);calls.push({method:options.method||'GET',headers:options.headers,body:options.body});
   const item=replies.shift();if(typeof item==='function')return item(options);return Promise.resolve(response(item||{ok:true,revision:1,connectors:[],servers:[],templates:{}}));
  };
  // The exact string the model is offered for openclaw's WhatsApp read, and the schema its probe reported.
  const PEER_TOOL='peer_openclaw__mcp_mail_list_messages_662289dd';
  const PEER_SCHEMA='{"type":"object","properties":{"conversation_id":{"type":"string"},"n":{"type":"integer"}},"required":["conversation_id"]}';
  const peer={key:'openclaw:mail',id:'mail',name:'Mail',where:'openclaw',scope:'peer',transport:'native',state:'enabled',enabled:true,tool_count:1,approved:1,discovered:1,revision:4,tools:[{name:PEER_TOOL,tool:'list_messages',description:'List one mailbox newest-first',schema:PEER_SCHEMA,approval:'read',published:true}],policy:{tier:'mcp',approval:'the peer decided each tool effect',note:'Runs on openclaw; its own write gates and approvals still decide.'}};
  const local={key:'mail_wasm',id:'mail_wasm',name:'Mail (WASI component)',where:'this node',scope:'local',transport:'stdio',state:'failing',enabled:false,tool_count:0,approved:2,discovered:0,error:'mcp_tool_schemas_changed',revision:2,tools:[{name:'mcp_mail_read_message_abc12345',tool:'read_message',description:'<script>attack</script>Search the message index',schema:'{"type":"object","properties":{}}',approval:'read',published:false,note:'approved_but_not_discovered'}],policy:{tier:'mcp',approval:'each tool is approved locally as read or write'}};
  const fixture={ok:true,revision:2,read_only:false,counts:{connectors:2,here:1,from_peers:1,enabled:1,tools:1},adapters:[{name:'WhatsApp',capabilities:['snapshot reads','media'],note:'Jobs own wakes'}],servers:[{id:'mail_wasm',name:'Mail (WASI component)',definition:{transport:'stdio',tools:{read_message:'read'}}}],templates:{mail:{id:'mail',transport:'stdio',program:'node',args:['mcp-mail.mjs'],tools:{read_message:'read'}}},connectors:[local,peer]};
  busy=true;const box=document.getElementById('mcp-box'),panel=box.querySelector('wa-mcps');box.hidden=false;
  let resolveFirst;replies.push(()=>new Promise(resolve=>resolveFirst=resolve));loadTopic('mcp-box');await tick();const second=refreshMcps();await tick();check(calls.length===1,'busy main does not queue MCP inventory and independent reads coalesce');
  resolveFirst(response(fixture));await second;await until(()=>panel.data,'first inventory');
  const text=()=>panel.list.textContent;
  check(text().includes('WhatsApp (native)')&&text().includes('openclaw:whatsapp_native'),'peer connector rendered with its name and key');
  check(text().includes('WhatsApp operator reads')&&text().includes('runs on this node'),'local connector rendered with where it runs');
  check(text().includes('enabled · native · runs on openclaw · 1 tool callable now'),'peer state, transport, host and tool count');
  check(text().includes('failing · stdio · runs on this node · 0 tools callable now · last error: mcp_tool_schemas_changed'),'local failure shows its last error');
  check(text().includes('built-in profile-managed MCP'),'the built-in WhatsApp profile is shown separately from connectors');
  check(text().includes('policy: tier mcp'),'the policy tier is rendered');
  check(!panel.list.querySelector('img,script'),'connector metadata rendered as text');
  check(panel.list.querySelectorAll('details').length===2,'one controls block per connector');
  check(text().includes('Controls it gives the model (1)'),'each block says how many controls it holds');
  check(text().includes(PEER_TOOL),'the exact model-visible name is shown verbatim');
  check(text().includes('schema: '+PEER_SCHEMA),'the input schema is shown verbatim');
  check(text().includes('Read one WhatsApp chat newest-first'),'the tool description is shown');
  check(calls.every(call=>call.method==='GET'),'opening never probes, connects or sends');
  const peerRow=panel.list.querySelector('[data-connector="openclaw:whatsapp_native"]'),localRow=panel.list.querySelector('[data-connector="whatsapp"]');
  check(peerRow&&localRow,'a connector row is addressable by its key');
  const peerToggle=[...peerRow.querySelectorAll('button')].find(button=>button.textContent==='Turn off');
  check(!!peerToggle,'an enabled connector offers Turn off');
  check([...localRow.querySelectorAll('button')].some(button=>button.textContent==='Turn on'),'a disabled connector offers Turn on');
  replies.push({ok:true,action:'disable',connector:'openclaw:whatsapp_native',enabled:false,revision:5});
  replies.push({...fixture,revision:5,connectors:[local,{...peer,state:'disabled',enabled:false,tool_count:0,revision:5}]});
  peerToggle.click();await tick();
  const toggleBody=JSON.parse(posts().at(-1).body);
  check(toggleBody.action==='toggle'&&toggleBody.connector==='openclaw:whatsapp_native'&&toggleBody.enable===false,'the toggle asks for exactly that connector and direction');
  check(toggleBody.expected_revision===4,'the toggle carries the revision the row was drawn from');
  await until(()=>panel.data&&panel.data.revision===5,'the peer toggle to settle');check(text().includes('disabled · native · runs on openclaw · 0 tools callable now'),'the peer answer settles the row and reloads it');
  panel.inventory={...fixture,read_only:true};
  const readOnlyToggle=[...panel.list.querySelectorAll('button')].find(button=>button.textContent==='Turn on'||button.textContent==='Turn off');
  check(readOnlyToggle.disabled,'a read-only window cannot toggle');
  check(panel.notice.textContent.includes('read-only'),'the read-only reason is stated');
  panel.inventory={...fixture,read_only:false,connectors:[{...peer,note:'connector_registry_not_reported'}]};
  const untoggleable=[...panel.list.querySelectorAll('button')].find(button=>button.textContent==='Turn off');
  check(untoggleable.disabled&&/nothing to toggle/.test(untoggleable.title),'a peer without a reported registry offers no control');
  panel.inventory={ok:true,revision:2,read_only:false,servers:fixture.servers,templates:fixture.templates};
  check(text().includes('did not report a connector list'),'an older node is named, not shown as a silent empty list');
  panel.inventory=fixture;panel.editor.value='draft survives failed read';replies.push(()=>Promise.reject(Error('read fixture failure')));await refreshMcps();
  check(text().includes('WhatsApp (native)')&&panel.editor.value==='draft survives failed read','a failed read retains the inventory and the editor');
  check(panel.notice.textContent.includes('Refresh to retry'),'a failed read leaves a visible explicit retry');
  panel.template.click();check(JSON.parse(panel.editor.value).id==='whatsapp','the template loads a disabled local definition');
  panel.editor.value='not JSON';const before=posts().length;panel.save.click();await tick();check(posts().length===before&&panel.notice.textContent.includes('Invalid JSON'),'an invalid editor cannot start a request');
  panel.editor.value=JSON.stringify(fixture.templates.whatsapp);replies.push(()=>new Promise(resolve=>controlResolve=resolve));panel.save.click();panel.save.click();await tick();check(posts().length===before+1,'mutating controls are single flight');
  const posted=JSON.parse(posts().at(-1).body);check(posted.action==='put'&&posted.expected_revision===2&&posted.definition.id==='whatsapp','a save uses the captured registry revision and never implies enable');
  check(panel.save.disabled,'a pending control cannot paint a successful change');
  replies.push({...fixture,revision:3});controlResolve(response({ok:true,enabled:false}));await until(()=>panel.data&&panel.data.revision===3,'the save to settle');check(!panel.save.disabled,'the persistent answer and a fresh inventory settle the control');
  panel.editor.value='node A draft';const oldNode=activeNode;activeNode='mcp-private-node-B';replies.push({ok:true,revision:8,connectors:[],servers:[],templates:{}});await refreshMcps();
  check(text().includes('No MCP connector is registered here')&&!text().includes('WhatsApp (native)'),'a node/account change clears the foreign inventory');check(panel.editor.value==='','a draft is scope specific');
  panel.editor.value='node B draft';activeNode=oldNode;replies.push(fixture);await refreshMcps();check(panel.editor.value==='node A draft','returning to a node restores its own draft');
  let stale;replies.push(()=>new Promise(resolve=>stale=resolve));const pending=refreshMcps();await tick();activeNode='mcp-private-node-B';replies.push({ok:true,revision:9,connectors:[],servers:[],templates:{}});await refreshMcps();stale(response({...fixture,revision:100}));await pending;check(panel.data.revision===9,'a delayed answer for a foreign scope is ignored');
  activeNode=oldNode;replies.push(fixture);await refreshMcps();
  const child=document.createElement('wa-agent-session');document.body.append(child);child.task={session_id:'mcp-child',subagent_id:'mcp-child',state:'running',settled:false};child.input.value='child draft';
  replies.push(fixture);await refreshMcps();check(child.input.value==='child draft'&&calls.at(-1).method==='GET','child activity and draft are untouched by the inventory');child.remove();
  replies.push({ok:false,error:'forbidden'});replies.push({...fixture,read_only:true});
  const toggleNow=()=>[...panel.list.querySelectorAll('button')].find(button=>button.textContent==='Turn on'||button.textContent==='Turn off');
  toggleNow().click();await until(()=>panel.notice.textContent.includes('Not changed:'),'the refusal notice');check(panel.notice.textContent.includes('Not changed: forbidden'),'a refusal is reported as a decision, not as an unknown outcome');
  replies.push(fixture);await refreshMcps();const settledPosts=posts().length;replies.push(()=>Promise.reject(Error('lost control response')));toggleNow().click();await tick();await tick();
  await until(()=>panel.notice.textContent.includes('never replay automatically'),'the uncertain notice');check(posts().length===settledPosts+1,'an unknown outcome is never replayed automatically');
  document.getElementById('panel').style.width='540px';busy=false;window.fetch=originalFetch;
  setEngine(true);box.hidden=false;box.closest('.engine-topic').scrollIntoView({block:'start'});check(document.body.classList.contains('engine'),'actual Engine mode for visual proof');
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(error){report.dataset.status='fail';report.textContent=String(error.stack||error);}
})();

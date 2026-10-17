(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.style.display='none';document.body.append(report);
 let checks=0;const check=(v,label)=>{checks++;if(!v)throw Error(label);};const tick=async()=>{for(let i=0;i<20;i++)await Promise.resolve();};
 try{
  await window.rendererLoaded;await tick();for(let i=1;i<10000;i++){clearTimeout(i);clearInterval(i);}
  check(commandMatches('/provider')[0]?.name==='/provider','bare deterministic provider command');
  input.value='/';syncCommands();check(commandMenu.querySelectorAll('.menu-item').length===8,'rendered menu matches eight-command contract');
  check(COMMANDS.length===8&&COMMANDS.slice(0,6).map(c=>c.name).join(',')==='/new,/update,/merge,/merge all,/efficiency_report,/orchestration','established six command defaults/order preserved');
  check(COMMANDS[6].name==='/provider'&&COMMANDS[7].name==='/login','management commands extend rather than displace defaults');
  commandMenu.close();input.value='';
  let calls=[],release=null;const old=apiFetch,oldConfirm=window.confirm,oldSelect=setProvider;
  const data={providers:[{id:'openai-sub',label:'OpenAI subscription',source:'native',configured:true,enabled:true},{id:'opencode-go',label:'OpenCode Go',source:'vault',configured:true,enabled:true,operator_url:'http://127.0.0.1:8801'}],quota:'Monthly GoUsageLimitError is account/workspace quota. A key from the same exhausted workspace may still fail. No automatic retry or provider switch.'};
  apiFetch=async(path,options={})=>{calls.push({path,body:options.body});check(path==='provider-management','management never calls inference/chat');return{json:async()=>data};};
  window.confirm=()=>false;let selections=0;setProvider=async()=>{selections++;};
  await openProviderManagement();const panel=document.querySelector('wa-provider-manager');
  check(panel.textContent.includes('OpenAI subscription')&&panel.textContent.includes('OpenCode Go'),'friendly two routes rendered');
  check(panel.querySelectorAll('section').length===2,'only two supported routes');
  check(panel.textContent.includes('same exhausted workspace'),'monthly quota truthful');
  check(panel.querySelector('input')===null,'no chat-origin credential input');
  check(!!panel.entry&&!panel.entry.frame&&panel.textContent.includes('Inline key box setup required'),'missing bound route offers truthful setup state, not a parent-owned secret input');
  check(calls.length===1&&selections===0,'opening has no inference or account/selection side effect');
  const click=(action,id)=>panel.dispatchEvent(new CustomEvent('provider-action',{detail:{action,id}}));
  click('begin','openai-sub');await tick();check(calls.length===1,'cancel confirmation sends nothing');
  window.confirm=()=>true;let deviceCalls=0,releasePoll=null,unknownBegin=false;
  apiFetch=async(path,options={})=>{
    check(path==='provider-management','device management never calls inference');
    if(!options.body)return{json:async()=>data};
    const request=JSON.parse(options.body);deviceCalls++;
    if(request.action==='begin'&&unknownBegin)throw Error('synthetic ambiguous begin');
    const result={state:request.action==='cancel'?'cancelled':'pending',operation:request.operation,user_code:'FIXTURE-CODE',verification_url:'https://auth.openai.com/codex/device'};
    if(request.action==='poll')return new Promise(resolve=>{releasePoll=()=>resolve({json:async()=>result});});
    return{json:async()=>result};
  };
  click('begin','openai-sub');await tick();check(panel.textContent.includes('FIXTURE-CODE'),'confirmed native login renders human device contract');
  click('poll');click('poll');await tick();check(deviceCalls===2,'device poll is single flight');releasePoll();await tick();
  click('cancel');await tick();check(panel.login===null&&!sessionStorage.getItem('wa-provider-device:'+String(activeNode)+':'+String(me.user?.id||'operator')),'native cancel clears transient operation state');
  unknownBegin=true;click('begin','openai-sub');await tick();const sent=deviceCalls;click('poll');await tick();check(deviceCalls===sent&&panel.textContent.includes('No automatic replay'),'ambiguous native begin held without replay');
  click('cancel');await tick();check(panel.login===null,'unknown native operation can be explicitly cancelled');
  busy=true;click('select','opencode-go');await tick();check(selections===0&&panel.textContent.includes('Run active'),'busy selection known no effect');busy=false;
  const previous=activeNode;activeNode='foreign-node';click('select','opencode-go');await tick();check(selections===0&&panel.textContent.includes('Node/account changed'),'scope drift refuses wrong-node action');activeNode=previous;
  click('close');await tick();check(!providerManagementPanel.open,'close recovers without credential deletion');
  await openProviderManagement();check(providerManagementPanel.open,'reopen same management state');
  panel.message='Recovery controls available; no failed request replayed.';
  check(panel.getBoundingClientRect().bottom<=input.getBoundingClientRect().top,'management remains bounded above composer');
  apiFetch=old;setProvider=oldSelect;window.confirm=oldConfirm;
  const previousThread=chatSession;COMMANDS[0].run();await tick();
  check(chatSession!==previousThread&&!!messages.querySelector('.thread-notice'),'first command still starts a new recoverable thread');
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(error){report.dataset.status='fail';report.textContent=String(error.stack||error);}
})();

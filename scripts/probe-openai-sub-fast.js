(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.style.display='none';document.body.append(report);
 let checks=0;const check=(v,label)=>{checks++;if(!v)throw Error(label);};const tick=async()=>{for(let i=0;i<30;i++)await Promise.resolve();};
 try{
  await window.rendererLoaded;await tick();for(let i=1;i<10000;i++){clearTimeout(i);clearInterval(i);}
  activeNode='';busy=false;me.role='master';settingsChanging=false;
  settings={...settings,provider:'openai-sub',model:'gpt-6.1-sol',settings_revision:10,
   providers:[{id:'openai-sub',label:'OpenAI subscription',configured:true,models:['gpt-6.1-sol']}],
   reasoning:{supported:true,levels:['low','medium','high'],selected:'low'},
   fast_mode:{preference:'off',enabled:false,model_support:'documented',account_entitlement:'unknown'}};
  renderControls();const controls=document.getElementById('fast-mode-controls');
  check(controls.closest('#status-balloon'),'Fast is INSIDE existing status balloon');
  check(!controls.hidden&&!fastToggle.checked&&!fastToggle.disabled,'old default OFF and usable');
  check(controls.textContent.includes('2.5×')&&controls.querySelector('a').href==='https://learn.chatgpt.com/docs/agent-configuration/speed','premium and primary provenance');
  let sent=[];const old=apiFetch;
  apiFetch=async(route,options)=>{
   check(route==='fast-mode','only scoped preference endpoint, no inference');const body=JSON.parse(options.body);sent.push(body);
   return{ok:true,json:async()=>({...settings,settings_revision:settings.settings_revision+1,fast_mode:{...settings.fast_mode,preference:body.value}})};
  };
  fastToggle.checked=true;fastToggle.dispatchEvent(new Event('change'));await tick();
  check(sent.length===1&&sent[0].value==='on'&&sent[0].revision===10,'explicit ON CAS');
  check(fastToggle.checked&&settings.fast_mode.preference==='on','confirmed ON restored');
  fastWorkers.checked=true;fastWorkers.dispatchEvent(new Event('change'));await tick();
  check(sent.at(-1).value==='coding'&&fastWorkers.checked,'explicit ordinary coding inheritance');
  fastToggle.checked=false;fastToggle.dispatchEvent(new Event('change'));await tick();
  check(sent.at(-1).value==='off'&&!fastToggle.checked,'persistent OFF escape');
  const revision=settings.settings_revision;
  check(!acceptSettings({...settings,settings_revision:revision-1,fast_mode:{preference:'on'}}),'stale async read cannot enable Fast');
  check(settings.fast_mode.preference==='off','stale preference untouched');
  let release;apiFetch=()=>new Promise(resolve=>{release=resolve;});
  fastToggle.checked=true;fastToggle.dispatchEvent(new Event('change'));await tick();activeNode='foreign';
  release({ok:true,json:async()=>({...settings,settings_revision:settings.settings_revision+1,fast_mode:{preference:'on'}})});await tick();
  check(settings.fast_mode.preference==='off','delayed write reply cannot paint another node');activeNode='';
  busy=true;paintFastMode();check(fastToggle.disabled&&fastWorkers.disabled,'active run locked');busy=false;
  me.role='guest';paintFastMode();check(fastToggle.disabled,'guest cannot upcharge');me.role='master';
  activeNode='foreign';paintFastMode();check(fastToggle.disabled,'remote preference refused');activeNode='';
  settings.provider='opencode-go';paintFastMode();check(controls.hidden,'Go has no Fast control');
  settings.provider='openai-sub';settings.fast_mode={preference:'on',model_support:'unknown',error:'fast_mode_model_unknown'};paintFastMode();
  check(!fastToggle.disabled&&fastToggle.checked,'unsupported chosen preference can be turned OFF');
  settings.fast_mode={preference:'off',model_support:'unknown'};paintFastMode();check(fastToggle.disabled,'unknown support cannot silently enable');
  settings.fast_mode={preference:'on',model_support:'documented'};settings.observability={last:{fast_mode:{requested:'priority',actual:'default'}}};paintFastMode();
  check(document.getElementById('fast-mode-note').textContent.includes('actual: default'),'downgrade visible');
  settings.observability={};paintFastMode();check(document.getElementById('fast-mode-note').textContent.includes('actual: unknown'),'missing actual unknown');
  document.getElementById('status-balloon').show();renderMetadataParts();
  settings.fast_mode={preference:'off',model_support:'documented'};renderMetadataParts();check(!fastToggle.checked,'other-window preference repaint');
  settings.fast_mode={preference:'on',model_support:'documented'};settings.observability={last:{fast_mode:{requested:'priority',actual:'default',matches_requested:false}}};renderMetadataParts();
  check(fastToggle.checked&&document.getElementById('fast-mode-note').textContent.includes('Provider tier differs'),'fresh actual tier repaint without replacing model controls');
  check(COMMANDS.slice(0,6).map(c=>c.name).join(',')==='/new,/update,/merge,/merge all,/efficiency_report,/orchestration','existing command defaults retained');
  apiFetch=old;renderControls();document.getElementById('status-balloon').show();
  report.dataset.status='pass';report.textContent=JSON.stringify({checks,skipped:0});
 }catch(error){report.dataset.status='fail';report.textContent=String(error.stack||error);}
})();

(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.hidden=true;document.body.append(report);
 let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};const tick=()=>Promise.resolve();
 try{
  await window.rendererLoaded;for(let i=0;i<200&&!transcriptReady;i++)await new Promise(r=>setTimeout(r,10));
  check(transcriptReady,'startup transcript ready');for(let i=1;i<10000;i++){clearTimeout(i);clearInterval(i);}document.body.classList.add('expanded');pendingReload=false;

  const savedApiFetch=apiFetch;
  const thread=chatSession;
  const posts=[];
  apiFetch=async(route,options)=>{
   if(route==='subagents'){
    const body=JSON.parse(options.body);posts.push(body);
    return {ok:true,status:200,json:async()=>({id:'steering-image-1',state:'queued',run_id:'image-run',ordinal:1})};
   }
   return savedApiFetch(route,options);
  };

  // The fixture arrives through the SAME intake the chat uses: the shell reads the File and draws
  // the chip. Nothing here pushes an attachment object by hand.
  const Reader=window.FileReader;
  window.FileReader=class {readAsDataURL(){this.result='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';queueMicrotask(()=>this.onload());}};
  chatShell.clearAttachments();attachments.length=0;chatShell.renderAttachments();
  const picture=new File(['fixture-image'],'steer.png',{type:'image/png'});
  const intake=await addFiles([picture]);
  check(intake.added===1&&intake.refused===0&&attachments.length===1&&attachments[0].kind==='image','the chat intake accepts the image file');
  check(chatShell.attachmentsEl.querySelectorAll('.attachment.attachment-image').length===1,'the same intake draws the image chip');

  busy=true;input.value='Show me what this is';draftGeneration++;
  await steerActiveRun();
  check(posts.length===1,'one steering request reaches the node route');
  const body=posts[0];
  check(body.action==='steer_session'&&body.session_id===thread,'the steering request keeps its action and thread');
  check(Array.isArray(body.images)&&body.images.length===1,'the steering payload carries the attached image');
  check(body.images[0].name==='steer.png'&&body.images[0].mime==='image/png'&&body.images[0].data.startsWith('data:image/png;base64,'),'the image keeps its name, mime and data URL');
  check(body.text==='Show me what this is'&&!body.text.includes('iVBOR'),'the picture is not converted into text to fake acceptance');
  check(attachments.length===0&&input.value==='','confirmed steering clears the draft it carried');
  check(!!messages.querySelector('wa-steering'),'the steering receipt is still drawn as a steering topic');

  // The refusal notice: the chat's existing pinned warning, one per attempt, withdrawn on its own.
  chatShell.warning.clearNotices();
  const warning=chatShell.warning;
  check(warning===document.querySelector('wa-chat-shell[primary] wa-chat-warning'),'the notice is the existing <wa-chat-warning> of the primary chat shell');
  check(warning.tagName==='WA-CHAT-WARNING'&&!warning.closest('wa-message'),'the notice is the chat warning element, never a transcript bubble');
  check(!messages.contains(warning),'the notice lives outside the transcript');

  attachments.push({kind:'image',name:'broken.png'});chatShell.renderAttachments();
  busy=true;input.value='try again';draftGeneration++;
  await steerActiveRun();
  check(!warning.hidden&&warning.textContent.includes('Steering accepts text only'),'a refused steer appears in the pinned warning, saw '+JSON.stringify(warning.textContent));
  const firstText=warning.textContent;
  const box=warning.getBoundingClientRect(),shellBox=chatShell.getBoundingClientRect();
  check(box.top-shellBox.top<24,'the notice sits at the top of the chat content');
  check(Math.abs(getComputedStyle(warning).top.replace('px','')-5)<2,'its top offset is the chat warning slot (5px)');

  await steerActiveRun();await steerActiveRun();
  check(warning.textContent===firstText,'repeated attempts replace one notice in place');
  check(Array.from(document.querySelectorAll('wa-chat-warning')).filter(el=>!el.hidden&&el.textContent.includes('Steering accepts')).length===1,'there is exactly one visible steering notice');

  const before=warning.getBoundingClientRect().top;messages.scrollTop+=120;
  check(Math.abs(warning.getBoundingClientRect().top-before)<1,'the notice stays pinned while the transcript scrolls');
  check(attachments.length===1&&input.value==='try again','a refused steer keeps its files and draft');

  const started=performance.now();
  for(let i=0;i<80&&!warning.hidden;i++)await new Promise(r=>setTimeout(r,50));
  const elapsed=Math.round(performance.now()-started);
  check(warning.hidden,'the notice withdraws on its own, still saw '+JSON.stringify(warning.textContent));
  check(elapsed<5000,'it disappears within a bounded time, took '+elapsed+'ms');
  check(warning.textContent===''&&!warning.hasAttribute('data-stale'),'the withdrawn notice leaves nothing in the slot');

  // Ordinary chat composition is untouched by sharing the intake with steering.
  attachments.length=0;chatShell.renderAttachments();
  const plain=JSON.parse(composedBody('plain words').body);
  check(composedBody('plain words').contentType==='application/json'&&plain.text==='plain words'&&!plain.images,'ordinary text-only chat still sends its text and no image part');
  window.FileReader=Reader;
  report.dataset.status='pass';report.textContent=JSON.stringify({ok:true,checks,skipped:0,steering_posts:posts.length,steering_images:body.images.length,dismissed_ms:elapsed});
 }catch(error){
  report.dataset.status='fail';report.textContent=JSON.stringify({ok:false,checks,error:String(error&&error.message||error)});
 }
})();

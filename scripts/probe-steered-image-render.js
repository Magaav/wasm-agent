// Browser probe: a steered turn draws the pictures it carried, through the same attachment renderer
// an ordinary sent turn uses. The control is this page's own ordinary send, and the comparison is
// the shared fingerprint helper (scripts/wa-probe-support.js, injected by the observer before every
// probe) - so a lookalike renderer that draws the same tag and class is still a divergence, and the
// failure message is one line naming the first diverging path. The transport half is asserted here
// too, so a green run cannot come from a payload change: the steer body still carries
// images:[{name,mime,data}].
(async()=>{
 const report=document.createElement('pre');report.id='wa-probe';report.hidden=true;document.body.append(report);
 let checks=0;const check=(ok,label)=>{if(!ok)throw Error(label);checks++;};
 check(typeof waProbeFingerprint==='function'&&typeof waProbeSameAs==='function'&&typeof waProbeDiff==='function','the observer must inject wa-probe-support.js before every probe');
 // The fixture image the intake reads: a real 1x1 PNG, so the browser can decode what it is given.
 const DATA='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';
 const picture=name=>new File(['fixture-image'],name,{type:'image/png'});
 try{
  await window.rendererLoaded;for(let i=0;i<200&&!transcriptReady;i++)await new Promise(r=>setTimeout(r,10));
  check(transcriptReady,'startup transcript ready');for(let i=1;i<10000;i++){clearTimeout(i);clearInterval(i);}document.body.classList.add('expanded');pendingReload=false;

  const savedApiFetch=apiFetch,steers=[];
  apiFetch=async(route,options)=>{
   let body=null;
   try{body=route==='subagents'&&options&&options.body?JSON.parse(options.body):null;}catch(error){body=null;}
   if(body&&body.action==='steer_session'){
    steers.push(body);
    return {ok:true,status:200,json:async()=>({id:'steered-image-'+steers.length,state:'queued',run_id:'image-run',ordinal:steers.length})};
   }
   return savedApiFetch(route,options);
  };
  const Reader=window.FileReader;
  window.FileReader=class{readAsDataURL(){this.result=DATA;queueMicrotask(()=>this.onload());}};
  // One intake for both halves: the pictures arrive through the chat's own reader, never by hand.
  // `settle` lets the ordinary send's own confirmation finish before a steering draft is built, so
  // the draft this probe reads is the one it built and not one a late callback replaced.
  const draft=async names=>{chatShell.clearAttachments();attachments.length=0;chatShell.renderAttachments();return addFiles(names.map(picture));};
  const settle=async()=>{for(let i=0;i<20;i++)await new Promise(r=>setTimeout(r,5));};

  // The control is this page's own ordinary send, of the SAME fixture picture the steer will carry.
  // Whatever markup it draws is what a steered turn has to draw - not a shape this probe invents for
  // itself, and with the same file name so tag, classes, alt/title and the src bytes all compare.
  const intake=await draft(['steer.png']);
  check(intake.added===1&&attachments.length===1&&attachments[0].kind==='image','the chat intake accepts the picture');
  input.value='What is in this picture?';draftGeneration++;
  document.getElementById('composer').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
  const sent=messages.querySelector('wa-message.user .message-images .message-image');
  check(!!sent,'the normal send path draws the picture in its user turn');
  check(sent.getAttribute('src')===DATA,'the normal send path resolves the fixture image data');
  // THE CONTROL. The gallery this page's own ordinary send produced; a steered turn has to match it
  // whole - tag, classes, the picture's own attributes and its bytes (as a readable src digest) -
  // through the shared helper, whose failure is one line naming the first diverging path.
  const SHAPE={ignore:['style','id']};
  // For the three-picture turn the names differ by design, and they are asserted as exact values
  // above, so only the name is left out of the structural comparison there.
  const SHAPE_ANY_NAME={ignore:['style','id','alt','title']};
  const control=sent.parentElement;
  const controlShape=waProbeFingerprint(control,SHAPE);
  await settle();

  // The steer: the same intake, one picture, while the run is in flight.
  await draft(['steer.png']);
  check(attachments.length===1&&attachments[0].kind==='image','the steering draft carries one picture');
  busy=true;input.value='Show me what this is';draftGeneration++;
  await steerActiveRun();
  check(steers.length===1,'one steering request reaches the node route');
  const body=steers[0];
  check(body.action==='steer_session','the steering body keeps its action');
  check(Array.isArray(body.images)&&body.images.length===1,'the steer body still carries images:[{name,mime,data}]');
  check(body.images[0].name==='steer.png'&&body.images[0].mime==='image/png'&&body.images[0].data===DATA,'the payload image keeps its name, mime and data');
  check(!String(body.text).includes('iVBOR'),'the picture is not turned into prompt text to fake a picture');
  const topic=messages.querySelector('wa-steering[data-steering-id="steered-image-1"]');
  check(!!topic,'the steered turn is drawn as a steering topic');
  const drawn=topic.querySelectorAll('.message-images .message-image');
  // The helper first, so a steered turn that drew nothing fails as a named root divergence rather
  // than as a count: a missing node is a divergence, not an exception.
  const steeredSame=waProbeSameAs(control,drawn[0]&&drawn[0].parentElement,SHAPE);
  check(steeredSame.equal,'the steered picture is the element the normal send path draws: '+waProbeDiff(steeredSame));
  check(drawn.length===1,'the steered turn shows its picture; it has '+drawn.length+' attachment element(s)');
  check(drawn[0].alt==='steer.png'&&drawn[0].getAttribute('src')===DATA,'the steered picture resolves to the fixture image data');
  check(!drawn[0].closest('.attachments'),'the picture is in the steered turn, not the composer strip');
  await settle();

  // Several pictures, each with its own identity.
  const three=await draft(['one.png','two.png','three.png']);
  check(attachments.length===3,'three pictures enter the steering draft, saw '+attachments.length+' added='+three.added+' refused='+three.refused+' stale='+three.stale.length);
  busy=true;input.value='Three of them';draftGeneration++;
  await steerActiveRun();
  check(steers.length===2&&steers[1].images.length===3,'the second steer carries all three images');
  const many=messages.querySelector('wa-steering[data-steering-id="steered-image-2"]');
  const manyDrawn=many?many.querySelectorAll('.message-image'):[];
  check(manyDrawn.length===3,'the steered turn shows all three pictures, saw '+manyDrawn.length);
  check(Array.from(manyDrawn).map(node=>node.alt).join(',')==='one.png,two.png,three.png','each steered picture keeps its own name');
  // Three of them, each picture element compared to the control's picture element: the shape does
  // not drift per element. The gallery holds three children by design here, so the element is the
  // subject and the name is the only field left out (asserted exactly on the line above).
  Array.from(manyDrawn).forEach((node,index)=>{
   const one=waProbeSameAs(sent,node,SHAPE_ANY_NAME);
   check(one.equal,'steered picture '+(index+1)+' of 3 matches the normal send path: '+waProbeDiff(one));
  });
  await settle();

  // The state event the node sends when the steer is read into context carries no images: the
  // picture already drawn must survive it, or the turn loses its picture a second later.
  handleEvent({type:'steering',version:1,id:'steered-image-1',run_id:'image-run',state:'read',text:'Show me what this is',seq:9});
  const read=messages.querySelector('wa-steering[data-steering-id="steered-image-1"]');
  check(read.dataset.state==='read','the steering receipt took the read state');
  check(read.querySelectorAll('.message-image').length===1&&read.querySelector('.message-image').getAttribute('src')===DATA,'the picture survives the queued -> read state update');

  // Text-only steering is unchanged: no picture, and no empty gallery holding a place.
  chatShell.clearAttachments();attachments.length=0;chatShell.renderAttachments();
  busy=true;input.value='just words';draftGeneration++;
  await steerActiveRun();
  check(steers.length===3&&!steers[2].images,'a text-only steer still sends no image part');
  const plain=messages.querySelector('wa-steering[data-steering-id="steered-image-3"]');
  check(!!plain&&plain.querySelectorAll('.message-image').length===0&&!plain.querySelector('.message-images'),'a text-only steered turn draws no attachment element');
  check(/just words/.test(plain.body.textContent),'a text-only steered turn keeps its text');

  // A refused file still refuses, and appends no turn and no half-drawn chip.
  const drawnBefore=messages.querySelectorAll('.message-image').length;
  const topicsBefore=messages.querySelectorAll('wa-steering').length;
  attachments.push({kind:'image',name:'broken.png'});chatShell.renderAttachments();
  busy=true;input.value='try again';draftGeneration++;
  await steerActiveRun();
  check(steers.length===3,'a refused steer posts nothing');
  check(messages.querySelectorAll('wa-steering').length===topicsBefore,'a refused steer appends no steered turn');
  check(messages.querySelectorAll('.message-image').length===drawnBefore,'a refused steer draws no picture, saw '+(messages.querySelectorAll('.message-image').length-drawnBefore)+' extra');
  check(attachments.length===1&&input.value==='try again','a refused steer keeps its files and draft');

  window.FileReader=Reader;
  report.dataset.status='pass';report.textContent=JSON.stringify({ok:true,checks,skipped:0,
   steering_posts:steers.length,steering_images:body.images.length,steered_drawn:drawn.length,many_drawn:manyDrawn.length,
   normal_image:controlShape.children[0].tag+'.'+controlShape.children[0].classes.join('.'),
   steered_image:steeredSame.equal?'same as control':'differs: '+waProbeDiff(steeredSame),
   control_path:steeredSame.path||null});
 }catch(error){
  report.dataset.status='fail';report.textContent=JSON.stringify({ok:false,checks,error:String(error&&error.message||error)});
 }
})();

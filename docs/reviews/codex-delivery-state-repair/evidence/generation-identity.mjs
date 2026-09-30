// Read-only: what generation would a pass over this store compute, vs the settled/held intent's id?
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const SRC='C:/Users/Victor/AppData/Local/Temp/wa-verdict-43893c3/tip-run';
const leg=process.argv[2];
const {readRecord}=await import(pathToFileURL(path.join(SRC,'scripts','lib','delivery-store.mjs')).href);
const {eventIdentity}=await import(pathToFileURL(path.join(SRC,'scripts','lib','delivery-outbox.mjs')).href);
const {evaluate}=await import(pathToFileURL(path.join(SRC,'scripts','delivery-admission.mjs')).href);
const store=`C:/Users/Victor/AppData/Local/Temp/wa-verdict-43893c3/${leg}/intent-race/store`;
const record=readRecord(store,'change/delivery');
const decision=evaluate({repo:record.repository,record});
const subscription=decision.decision==='refused'?null:{id:'delivery-lane',revision:1};
const computed=eventIdentity(record,decision,subscription);
const held=Object.keys(record.outbox)[0];
console.log(JSON.stringify({leg,decision:decision.decision,recordReview:record.review.verdict,
  computedGeneration:computed,heldIntent:held,heldIntentState:record.outbox[held].state,
  sameGeneration:computed===held},null,1));

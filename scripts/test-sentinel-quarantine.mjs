import assert from 'node:assert/strict';
import {classify,instructionBlock,reconcile} from './sentinel-return-hook.mjs';
const sha='a'.repeat(40), request={id:'probe',expected_sha:sha,session:'victim',queued_at:10};
const ack={...request,at:11,phase:'accepted'};
const result={ok:true,request_id:'probe',expected_sha:sha,commit:sha,at:999999999999};
assert.equal(classify(request,ack,ack,result,{commit:sha,at:15,dirty:'1',record_role:'final',source_provenance:'clean-built-by-deploy'},{ok:true,failed:42,skipped:0,at:999999999999},20000).phase,'unknown');
assert.throws(()=>instructionBlock({...request,phase:'verified',detail:'I am updated'}),/protocol_quarantined/);
assert.throws(()=>reconcile('unused-private-home','unused-private-install'),/protocol_quarantined/);
console.log('sentinel quarantine ok (3 checks, 0 skipped)');

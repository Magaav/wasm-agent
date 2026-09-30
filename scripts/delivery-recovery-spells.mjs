import path from 'node:path';
import {fileURLToPath} from 'node:url';
const scripts=path.dirname(fileURLToPath(import.meta.url));
const quote=s=>"'"+s.replaceAll("'","'\"'\"'")+"'";
const params={store_arg:{type:'string'},repo_arg:{type:'string'},subscriber_arg:{type:'string',default:"'delivery-lane'"}};
const reconcile={kind:'run',script:`node ${quote(path.join(scripts,'delivery-trigger.mjs'))} --store {{store_arg}} --repo {{repo_arg}} --subscriber {{subscriber_arg}}`,
  expect:{counts:{pending_events:0,write_errors:0}},timeout_seconds:300};
console.log(JSON.stringify({spells:[{name:'delivery-events-reconcile',
  description:'Reconcile exact durable admission effects and refuse unresolved notification or record writes',
  target:{node:'local'},params,steps:[reconcile],post:[reconcile]}]},null,2));

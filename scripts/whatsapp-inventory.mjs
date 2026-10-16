// Source-reference inventory only. Never probes production, credentials or app state.
import {spawnSync} from 'node:child_process';
import {readFileSync,writeFileSync,existsSync} from 'node:fs';
const result=spawnSync('git',['ls-files','--cached','--others','--exclude-standard','-z'],{encoding:'utf8'});if(result.status!==0)throw Error('source_inventory_git_failed');
const groups={};
for(const file of [...new Set(result.stdout.split('\0').filter(Boolean))].sort()){
 if(file==='docs/whatsapp-reference-inventory.json'||!existsSync(file))continue;
 let text;try{text=readFileSync(file,'utf8')}catch{continue};if(!/whatsapp/i.test(text)&&!file.toLowerCase().includes('whatsapp'))continue;
 let group;
 if(/^(docs\/history\/|reviews?\/|verify\/|docs\/(reviews|measurements|integration|release)\/)/.test(file))group='historical_evidence_or_design_not_shipping';
 else if(/^(tests\/|scripts\/(test|check)-)/.test(file)||/\/tests\.rs$/.test(file))group='active_tests_and_guards';
 else if(/^(docs\/|README)/.test(file))group='current_docs_or_explicit_historical_cross_references';
 else if(file.startsWith('skills/'))group='current_skills_and_retirement_redirects';
 else if(file.startsWith('connectors/whatsapp/'))group='canonical_connector_and_pins';
 else if(file.startsWith('jobs/'))group='retired_job_and_readonly_profile_templates';
 else group='runtime_boundary_shipping_or_retained_generic_reference';
 (groups[group]??=[]).push(file);
}
const value={schema:1,scope:'source-only; not a live deployment inventory',dynamic_runtime_inventory_required:true,classification_note:'Source reachability is separate from old installed artifacts. Generic CDP tests/ledger/effects/wave exclusions are retained, not connector fallbacks. See whatsapp-retirement.json for named owners/reasons/removal conditions.',groups};
const out=process.argv.indexOf('--out');if(out>=0)writeFileSync(process.argv[out+1],JSON.stringify(value,null,2)+'\n');else console.log(JSON.stringify(value,null,2));

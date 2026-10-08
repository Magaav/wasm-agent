// Pin the authorized recovery distinction and the limits of the diagnosis; no live effects.
import fs from 'node:fs';import assert from 'node:assert/strict';
let checks=0;const check=(v,why)=>{assert(v,why);checks++;};
const repo=new URL('../',import.meta.url);const read=p=>fs.readFileSync(new URL(p,repo),'utf8');
const agents=read('AGENTS.md'),skill=read('skills/self-update/SKILL.md'),doc=read('docs/SENTINEL.md'),restore=read('scripts/restore-sentinel-task.ps1');
check(agents.includes('checked node-side `-RestoreOnly` task path'),'injected instruction recovery path');
check(skill.includes('Bound workspaces do not forbid'),'bound sessions cannot become recovery dead end');
check(!skill.includes('A stopped watcher cannot be revived from a run'),'retired blanket refusal cannot return');
check(!doc.includes('A stopped watcher can still only be restarted from outside a turn'),'retired doc refusal');
check(restore.includes('$taskSid -ne $currentSid'),'same task/operator SID');
check(restore.includes('-not $RestoreOnly -and $effectState'),'unknown reservation survives watcher restoration');
check(restore.includes('-not $RestoreOnly -and -not $matching.Count'),'restore-only cannot create deployment intent');
check(!restore.includes('Remove-Item')&&!restore.includes('Start-Process')&&!restore.includes('Register-ScheduledTask'),'no evidence clearing or alternate watcher');
const diagnosis=read('docs/RECOVERY-DIAGNOSIS-20261008.md');
for(const marker of ['20.236s','125,996','No reasoning/text/tool-selection delta','exact startup event type was not recorded','different notification effect','26eddb7','no historical reservation has been cleared'])check(diagnosis.includes(marker),'diagnosis boundary: '+marker);
console.log(JSON.stringify({ok:true,checks,skipped:0,live_effects:0,scope:'recovery instructions and evidence limits'}));

import fs from 'node:fs';import assert from 'node:assert/strict';
const text=fs.readFileSync(new URL('./install-sentinel-task.ps1',import.meta.url),'utf8');
assert(text.includes('"%~dp0wa-sentinel.exe" start >>'),'task must use supported console-independent start');
assert(!text.includes('"%~dp0wa-sentinel.exe" watch >>'),'foreground watcher must not inherit CMD console');
assert(text.includes('exit /b %errorlevel%'),'launcher errors must propagate');
assert(text.includes('-RunLevel Limited'),'task must not silently elevate');
assert(text.includes('ExecutionTimeLimit ([TimeSpan]::Zero)'),'existing task policy retained');
console.log(JSON.stringify({ok:true,checks:5,skipped:0,scope:'task launcher source contract',task_effects:0}));

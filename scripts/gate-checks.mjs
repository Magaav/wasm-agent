// Discover checks without starting a build or consulting the live runtime.
import fs from 'node:fs';
export function catalog(repo) {
  return [
    ...fs.readdirSync(`${repo}/tests`).filter(f=>f.endsWith('.js')).sort().map(f=>({
      id:`js:${f}`, command:[process.execPath,`tests/${f}`], verdict:'js',
      resources:{cpu:1, memory_mb:256, exclusive:[]}, coverage:[`tests/${f}`,'ui/*','scripts/whatsapp-*'],
      isolation:'private home; in-process DOM or scratch listener; no live node'})),
    {id:'selection-state',command:[process.execPath,'scripts/test-selection-state.cjs'],binary:true,verdict:'proof',proof_kind:'selection',minimum:9,
      available:fs.existsSync(`${repo}/scripts/test-selection-state.cjs`),resources:{cpu:1,memory_mb:256,exclusive:[]},coverage:['lua/core/selection_state.lua'],isolation:'real independent processes; private SQLite/home; no inference'},
    {id:'recovery-windows',command:[process.execPath,'scripts/test-recovery-two-window.cjs','--embedded'],binary:true,verdict:'proof',proof_kind:'recoveryWindows',minimum:13,platform:'win32',
      available:fs.existsSync(`${repo}/scripts/test-recovery-two-window.cjs`),resources:{cpu:1,memory_mb:1024,exclusive:['browser']},coverage:['ui/*','rust/wa-host/src/serve.rs'],isolation:'two real Chromium contexts; private node/home/DB/ports; mock inference'},
    {id:'ui-browser',command:['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File','scripts/test-ui.ps1'],verdict:'browser',
      resources:{cpu:1,memory_mb:1024,exclusive:['browser']},coverage:['ui/*'],isolation:'private DB, home, browser profile and dynamically allocated ports'},
    {id:'install-isolation',command:[process.execPath,'scripts/test-install-isolation.mjs'],verdict:'js',
      resources:{cpu:1,memory_mb:128,exclusive:[]},coverage:['scripts/upgrade.sh','scripts/verify-install.sh'],isolation:'private home/install; extracted real shipping block'},
    {id:'finish-contract',command:[process.execPath,'scripts/test-parallel-finish.mjs'],verdict:'exit',
      resources:{cpu:1,memory_mb:256,exclusive:['fixture-git']},coverage:['skills/parallel-evolution/scripts/finish.mjs'],isolation:'private Git repository and reservation queue'},
    {id:'wave-lifecycle',command:[process.execPath,'scripts/test-wave-lifecycle.mjs'],binary:false,verdict:'proof',proof_kind:'waveLifecycle',minimum:40,
      available:fs.existsSync(`${repo}/scripts/test-wave-lifecycle.mjs`),resources:{cpu:1,memory_mb:512,exclusive:['fixture-git']},coverage:['scripts/lib/wave-*.mjs','lua/core/wave*.lua'],isolation:'private Git/home/DB and native children; public adapter uses real Orca fixture resources'},
    {id:'wave-retire',command:[process.execPath,'scripts/test-wave-retire.mjs'],binary:false,verdict:'proof',proof_kind:'waveRetire',minimum:20,
      available:fs.existsSync(`${repo}/scripts/test-wave-retire.mjs`),resources:{cpu:1,memory_mb:512,exclusive:['fixture-git']},coverage:['scripts/lib/wave-*.mjs','lua/core/wave*.lua'],isolation:'private Git/home/DB and native children; public adapter uses real Orca fixture resources'},
    {id:'wave-executor',command:[process.execPath,'scripts/test-wave-executor.cjs'],binary:true,verdict:'proof',proof_kind:'waveExecutor',minimum:11,
      available:fs.existsSync(`${repo}/scripts/test-wave-executor.cjs`),resources:{cpu:1,memory_mb:512,exclusive:['fixture-git']},coverage:['scripts/lib/wave-*.mjs','lua/core/wave*.lua'],isolation:'private Git/home/DB and native children; public adapter uses real Orca fixture resources'},
    {id:'wave-proof',command:[process.execPath,'scripts/test-wave-proof.mjs'],binary:false,verdict:'proof',proof_kind:'waveProof',minimum:18,
      available:fs.existsSync(`${repo}/scripts/test-wave-proof.mjs`),resources:{cpu:1,memory_mb:512,exclusive:['fixture-git']},coverage:['scripts/lib/wave-*.mjs','lua/core/wave*.lua'],isolation:'private Git/home/DB and native children; public adapter uses real Orca fixture resources'},
    {id:'wave-restart',command:[process.execPath,'scripts/test-wave-restart.mjs'],binary:false,verdict:'proof',proof_kind:'waveRestart',minimum:9,
      available:fs.existsSync(`${repo}/scripts/test-wave-restart.mjs`),resources:{cpu:1,memory_mb:512,exclusive:['fixture-git']},coverage:['scripts/lib/wave-*.mjs','lua/core/wave*.lua'],isolation:'private Git/home/DB and native children; public adapter uses real Orca fixture resources'},
    {id:'wave-public',command:[process.execPath,'scripts/test-wave-public.mjs'],binary:true,verdict:'proof',proof_kind:'wavePublic',minimum:20,
      available:fs.existsSync(`${repo}/scripts/test-wave-public.mjs`),resources:{cpu:1,memory_mb:512,exclusive:['fixture-git']},coverage:['scripts/lib/wave-*.mjs','lua/core/wave*.lua'],isolation:'private Git/home/DB and native children; public adapter uses real Orca fixture resources'},
    {id:'full',command:['bash','scripts/test.sh'],verdict:'smoke',
      resources:{cpu:'WA_GATE_JOBS or cargo default',memory_mb:null,exclusive:['production-gate']},coverage:['*'],
      isolation:'full gate owns scratch home; requires production reservation; run finish.mjs gate'}
  ];
}

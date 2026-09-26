// Mechanical finish evidence. Review, conflict resolution and repairs stay with the agent.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const [mode, directory, expectedHead] = process.argv.slice(2);
const repo = path.resolve(directory || process.cwd());
const runner = fileURLToPath(import.meta.url);
const sha = text => crypto.createHash('sha256').update(text).digest('hex');
const quote = text => "'" + text.replaceAll("'", "'\"'\"'") + "'";
function git(...args) {
  const result = spawnSync('git', args, {cwd:repo, encoding:'utf8', windowsHide:true,
    timeout:60000, maxBuffer:8*1024*1024});
  if (result.error || result.status !== 0) throw Error(result.error?.message || result.stderr || `git ${args[0]} exited ${result.status}`);
  return result.stdout.trim();
}
function inspect() {
  const checks = [];
  const check = (name, operation) => {
    try { const detail = operation(); checks.push({name,ok:true,detail}); return detail; }
    catch (error) { checks.push({name,ok:false,error:String(error.message)}); return null; }
  };
  const require = (condition, detail) => { if (!condition) throw Error(detail); return true; };
  const head = check('revision', () => {
    const actual = git('rev-parse','HEAD');
    require(/^[a-f0-9]{40,64}$/.test(expectedHead || '') && actual === expectedHead,
      `expected HEAD ${expectedHead}; observed ${actual}`);
    return actual;
  });
  const tree = check('source_tree', () => git('rev-parse','HEAD^{tree}'));
  const branch = check('branch', () => git('symbolic-ref','--short','HEAD'));
  check('clean', () => require(git('status','--porcelain') === '', 'uncommitted changes remain'));
  check('fresh_remote_refs', () => git('fetch','--prune','origin'));
  check('current', () => require(git('rev-list','--count','HEAD..origin/main') === '0', 'branch is behind origin/main'));
  check('pushed', () => {
    const upstream = git('rev-parse','--abbrev-ref','--symbolic-full-name','@{upstream}');
    require(upstream === `origin/${branch}`, `publish this branch with its own upstream; observed ${upstream}`);
    require(git('rev-list','--left-right','--count',`HEAD...${upstream}`).split(/\s+/).every(n => n === '0'),
      `branch and ${upstream} differ; sync/push is unfinished`);
    return upstream;
  });
  check('merge_proof', () => git('merge-tree','--write-tree','origin/main','HEAD'));
  return {repository_ready:checks.every(item => item.ok),repo,head,tree,branch,checks,
    inference_required:['one concern and patch review','impact audit and its coverage','integration/deployment when requested']};
}
function receiptPath() { return path.resolve(repo, git('rev-parse','--git-path','wa-finish-gate.json')); }
function verify(state) {
  if (!state.repository_ready) return {...state,gate_verified:false};
  try {
    const receipt = JSON.parse(fs.readFileSync(receiptPath(),'utf8'));
    if (receipt.schema !== 1 || receipt.repo !== repo || receipt.tree !== state.tree || receipt.passed !== true)
      throw Error('no passing gate evidence for this source tree');
    if (receipt.log_sha256 !== sha(fs.readFileSync(receipt.log))) throw Error('gate log differs from recorded evidence');
    return {...state,gate_verified:true,tested_head:receipt.head,equivalence:'git_tree',skipped:receipt.skipped,gate_log:receipt.log};
  } catch (error) { return {...state,gate_verified:false,gate_error:error.message}; }
}
function gate() {
  const before = inspect();
  if (!before.repository_ready) return {...before,gate_verified:false};
  const receipt = receiptPath(), log = `${receipt}.log`;
  fs.mkdirSync(path.dirname(receipt),{recursive:true});
  // Remove old proof before execution: a failed rerun must never leave a passing receipt.
  if (fs.existsSync(receipt)) fs.unlinkSync(receipt);
  const fd = fs.openSync(log,'w');
  let result;
  try {
    result = spawnSync('bash',['scripts/test.sh'],{cwd:repo,stdio:['ignore',fd,fd],
      windowsHide:true,timeout:3500*1000});
  } finally { fs.closeSync(fd); }
  const bytes = fs.readFileSync(log);
  const verdict = /(?:^|\n)smoke ok(?: \((\d+) skipped\))?\r?\n?$/u.exec(bytes.toString('utf8'));
  const after = inspect();
  if (result.error || result.status !== 0 || !verdict || !after.repository_ready || after.tree !== before.tree)
    return {...after,gate_verified:false,gate_error:result.error?.message || `gate exit=${result.status}; verdict=${Boolean(verdict)}`,
      gate_log:log};
  fs.writeFileSync(receipt,JSON.stringify({schema:1,repo,head:before.head,tree:before.tree,passed:true,
    skipped:Number(verdict[1] || 0),log,log_sha256:sha(bytes),at:new Date().toISOString()}));
  return verify(after);
}
function spellDefinitions() {
  // This repo uses bash on Windows too. Native paths are quoted as bash literals.
  const params = {runner_arg:{type:'string',default:quote(runner)},repo_arg:{type:'string'},head:{type:'string'}};
  const command = verb => `node {{runner_arg}} ${verb} {{repo_arg}} {{head}}`;
  const observation = (verb, expect) => ({kind:'run',script:command(verb),expect});
  const target = {node:'local'};
  return {spells:[
    {name:'parallel-evolution-ready',description:'Verify clean, current, pushed, mergeable repository state',target,params,
      steps:[observation('check',{repository_ready:true})],post:[observation('check',{repository_ready:true})]},
    {name:'parallel-evolution-gate',description:'Run the gate and verify its source-bound evidence',target,params,
      pre:[observation('check',{repository_ready:true})],
      steps:[{...observation('gate',{gate_verified:true}),timeout_seconds:3600}],
      post:[observation('verify',{repository_ready:true,gate_verified:true})]}
  ],composition:{name:'parallel-evolution-finish',description:'Verify repository readiness, run the gate, and recheck completion evidence',
    parts:[{name:'parallel-evolution-ready'},{name:'parallel-evolution-gate'}]}};
}
try {
  let result;
  if (mode === 'spell') result = spellDefinitions();
  else if (mode === 'check') result = inspect();
  else if (mode === 'gate') result = gate();
  else if (mode === 'verify') result = verify(inspect());
  else throw Error('usage: finish.mjs spell|check|gate|verify <absolute-repo> <expected-HEAD>');
  console.log(JSON.stringify(result));
} catch (error) { console.log(JSON.stringify({repository_ready:false,gate_verified:false,error:error.message})); process.exitCode=1; }

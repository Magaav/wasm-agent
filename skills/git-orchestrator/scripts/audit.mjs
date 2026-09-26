// Discover immutable integration inputs. Fetches refs, never edits a checkout or merges.
import {spawnSync} from 'node:child_process';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

function command(repo, program, args) {
  const result=spawnSync(program,args,{cwd:repo,encoding:'utf8',windowsHide:true,maxBuffer:32*1024*1024});
  return {status:result.status,stdout:result.stdout || '',stderr:result.error?.message || result.stderr || ''};
}
function requireResult(result,label) {
  if(result.status!==0) throw Error(`${label}: ${result.stderr || result.stdout}`);
  return result.stdout.trim();
}
export function parseWorktrees(raw) {
  return raw.split('\0\0').filter(Boolean).map(record=>{
    const item={};
    for(const field of record.split('\0')) {
      const at=field.indexOf(' ');
      item[at<0 ? field : field.slice(0,at)]=at<0 ? true : field.slice(at+1);
    }
    return item;
  });
}
function githubPRs(repo) {
  const name=JSON.parse(requireResult(command(repo,'gh',['repo','view','--json','nameWithOwner']),'GitHub repository')).nameWithOwner;
  if(!/^[\w.-]+\/[\w.-]+$/.test(name || '')) throw Error('Invalid GitHub repository name');
  const pages=JSON.parse(requireResult(command(repo,'gh',['api',`repos/${name}/pulls?state=open&per_page=100`,'--paginate','--slurp']),'Open PR discovery'));
  if(!Array.isArray(pages) || pages.some(page=>!Array.isArray(page))) throw Error('Invalid paginated PR response');
  return pages.flat().map(pr=>({number:pr.number,sha:pr.head?.sha,branch:pr.head?.ref,
    base:pr.base?.ref,draft:pr.draft,url:pr.html_url}));
}

export function audit(repo,{target='origin/main',includePRs=false,listPRs=githubPRs}={}) {
  if(!target || target.startsWith('-')) throw Error('Invalid integration target');
  repo=resolve(repo);
  const git=(...args)=>command(repo,'git',args);
  const errors=[],groups=new Map();
  const fetched=git('fetch','--all','--prune');
  if(fetched.status!==0) errors.push(`Fetch incomplete: ${fetched.stderr}`);
  const targetSha=requireResult(git('rev-parse','--verify',`${target}^{commit}`),'Integration target');
  const add=(sha,source)=>{
    if(!/^[a-f0-9]{40,64}$/.test(sha)) throw Error(`Invalid commit for ${source.ref}`);
    if(!groups.has(sha)) groups.set(sha,{sha,sources:[]});
    groups.get(sha).sources.push(source);
  };
  const refs=requireResult(git('for-each-ref','--format=%(refname)%00%(objectname)%00%(symref)','refs/heads','refs/remotes'),'Branch discovery');
  for(const line of refs.split('\n').filter(Boolean)) {
    const [ref,sha,symref]=line.split('\0');
    if(!symref) add(sha,{kind:'branch',ref});
  }
  let prs=[];
  try { prs=listPRs(repo); if(!Array.isArray(prs)) throw Error('Invalid PR list'); }
  catch(error) { prs=[]; errors.push(`PR discovery incomplete: ${error.message}`); }
  for(const pr of prs) {
    try {
      if(!Number.isSafeInteger(pr.number) || pr.number<1 || !/^[a-f0-9]{40,64}$/.test(pr.sha || '')) throw Error('Invalid PR identity');
      // Fetch GitHub's PR head even for a fork or a branch absent from origin refs.
      const ref=`refs/wasm-agent/merge/pr/${pr.number}`;
      requireResult(git('fetch','origin',`+refs/pull/${pr.number}/head:${ref}`),`PR #${pr.number} fetch`);
      const sha=requireResult(git('rev-parse','--verify',`${ref}^{commit}`),`PR #${pr.number} head`);
      if(sha!==pr.sha) throw Error('PR head moved during discovery; re-audit before integrating');
      add(sha,{kind:'pr',ref,number:pr.number,branch:pr.branch,base:pr.base,draft:!!pr.draft,url:pr.url});
    } catch(error) { errors.push(`PR #${pr.number}: ${error.message}`); }
  }
  const pendingPRs=[];
  for(const item of groups.values()) {
    if(item.sources.some(source=>source.kind==='pr') && git('merge-base','--is-ancestor',item.sha,targetSha).status!==0) pendingPRs.push(item.sha);
  }
  const candidates=[];
  for(const item of groups.values()) {
    const counts=git('rev-list','--left-right','--count',`${targetSha}...${item.sha}`);
    if(counts.status!==0) { errors.push(`Cannot compare ${item.sha}: ${counts.stderr}`); continue; }
    const [behind,ahead]=counts.stdout.trim().split(/\s+/).map(Number);
    item.ahead=ahead; item.behind=behind;
    item.state=ahead===0 ? 'contained' : 'pending';
    if(ahead>0 && !includePRs && pendingPRs.some(sha=>git('merge-base','--is-ancestor',sha,item.sha).status===0)) {
      item.state='excluded_pr';
      item.reason='Open PR work requires explicit /merge all, including branches containing its head.';
    }
    if(item.state==='pending') {
      const proof=git('merge-tree','--write-tree',targetSha,item.sha);
      item.merge=proof.status===0 ? 'clean' : proof.status===1 && proof.stdout.includes('CONFLICT') ? 'conflict' : 'error';
      if(item.merge!=='clean') item.detail=(proof.stdout+'\n'+proof.stderr).trim();
      if(item.merge==='error') errors.push(`Merge proof failed for ${item.sha}: ${item.detail}`);
    }
    candidates.push(item);
  }
  const worktrees=[];
  for(const wt of parseWorktrees(requireResult(git('worktree','list','--porcelain','-z'),'Worktree discovery'))) {
    const item={path:wt.worktree,branch:wt.branch || null,head:wt.HEAD,locked:wt.locked || false};
    const status=command(wt.worktree,'git',['status','--porcelain=v1','-z']);
    item.dirty=status.status===0 ? status.stdout.length>0 : null;
    if(status.status!==0) item.error=status.stderr;
    const counts=git('rev-list','--left-right','--count',`${targetSha}...${wt.HEAD}`);
    if(counts.status===0) [item.behind,item.ahead]=counts.stdout.trim().split(/\s+/).map(Number);
    else item.error=counts.stderr;
    item.sync=wt.detached ? 'detached_exempt' : item.locked ? 'locked' : item.dirty===null || counts.status!==0 ? 'unreadable' :
      item.dirty ? 'dirty_retained' : item.ahead>0 ? 'integrate_commits_first' : item.behind>0 ? 'fast_forward_after_idle_check' : 'current';
    worktrees.push(item);
  }
  const finalRefs=requireResult(git('for-each-ref','--format=%(refname)%00%(objectname)%00%(symref)','refs/heads','refs/remotes'),'Final branch discovery');
  if(finalRefs!==refs || requireResult(git('rev-parse','--verify',`${target}^{commit}`),'Final target')!==targetSha) {
    errors.push('Branch tips moved during discovery; re-audit before integrating');
  }
  const pending=candidates.filter(item=>item.state==='pending');
  return {schema_version:1,repo,target,target_sha:targetSha,include_prs:includePRs,discovery_complete:errors.length===0,
    integration_complete:errors.length===0 && pending.length===0,pending_tips:pending.length,
    errors,candidates,worktrees,
    note:'Integration covers committed tips. Worktree dirt, activity and optional branch deletion are separate follow-up; never discard them to claim convergence.'};
}

if(process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const args=process.argv.slice(2),includePRs=args.includes('--all');
    const [mode,repo,target,...extra]=args.filter(arg=>arg!=='--all');
    if(!['audit','verify'].includes(mode) || !repo || extra.length) throw Error('Usage: node audit.mjs audit|verify <repo> [target-ref] [--all]');
    const result=audit(repo,{target:target || 'origin/main',includePRs});
    console.log(JSON.stringify(result,null,2));
    process.exitCode=!result.discovery_complete || (mode==='verify' && !result.integration_complete) ? 1 : 0;
  } catch(error) { console.error(error.message); process.exitCode=1; }
}

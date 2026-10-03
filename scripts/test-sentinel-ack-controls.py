"""Guard-removal controls in private source copies; actual native CLI under owned Jobs."""
import argparse,json,os,pathlib,shutil,subprocess
p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--evidence',required=True);a=p.parse_args()
repo=pathlib.Path(a.repo).resolve();root=pathlib.Path(a.evidence).resolve();root.mkdir(parents=True,exist_ok=False)
env=os.environ.copy();env.update(CARGO_BUILD_JOBS='2',CARGO_TARGET_DIR=str(root/'target'))
controls=[('missing-ack', '    let intent=&binding["intent"];\n    let dir=', '    let intent=&binding["intent"];\n    return Ok((serde_json::json!({"at":intent["queued_at"]}),intent["queued_at"].as_u64().unwrap(),None));\n    let dir=', b'held', None),
          ('queue-clock', '.unwrap_or(ack_at+10);', '.unwrap_or(binding["intent"]["queued_at"].as_u64().unwrap()+10);', b'queue age cannot make ack check due', None),
          ('bound-check', '            bound_check(&saved,binding,&ack,at,now)?;', '            // causal control: shared current-check validation removed', b'wrong-id compose must refuse', 'binding')]
results=[]
for name,old,new,signature,mode in controls:
    case=root/name;case.mkdir()
    for crate in ['wa-sentinel','wa-operation','wa-jobs']:
        shutil.copytree(repo/'rust'/crate,case/'rust'/crate,ignore=shutil.ignore_patterns('target'))
    f=case/'rust/wa-sentinel/src/sentinel_return.rs';source=f.read_text();assert source.count(old)==1
    f.write_text(source.replace(old,new),newline='\n')
    built=subprocess.run(['cargo','build','--offline','--manifest-path',str(case/'rust/wa-sentinel/Cargo.toml')],env=env,capture_output=True)
    (case/'build.log').write_bytes(built.stdout+built.stderr);assert built.returncode==0
    binary=case/'wa-sentinel.exe';shutil.copy2(root/'target/debug/wa-sentinel.exe',binary)
    import hashlib
    (case/'binary-sha256.txt').write_text(hashlib.sha256(binary.read_bytes()).hexdigest())
    command=['python',str(repo/'scripts/test-sentinel-owned-job.py'),'--repo',str(repo),'--evidence',str(case/'job'),'--script',str(repo/'scripts/test-sentinel-ack.cjs'),'--argument',str(binary)]
    if mode:command.extend(['--argument',mode])
    run=subprocess.run(command,capture_output=True);(case/'runner.log').write_bytes(run.stdout+run.stderr)
    error=(case/'job/stderr.log').read_bytes();assert run.returncode!=0 and signature in error,(name,error)
    facts=json.loads((case/'job/job-receipt.json').read_text());assert facts['final_active']==0 and facts['exit']!=0
    results.append({'control':name,'red':True,'exit':facts['exit'],'final_active':facts['final_active']})
(root/'result.json').write_text(json.dumps({'controls':results,'checks':len(results),'skipped':0},indent=2))
print('native ack controls red ('+str(len(results))+' checks, 0 skipped)')

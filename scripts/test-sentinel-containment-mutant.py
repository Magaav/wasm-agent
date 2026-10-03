"""Private helper mutation drops root assignment, actual exact-Job membership must be red."""
import argparse,pathlib,subprocess,json,hashlib
p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--evidence',required=True);a=p.parse_args();repo=pathlib.Path(a.repo).resolve();root=pathlib.Path(a.evidence).resolve();root.mkdir(parents=True,exist_ok=False)
source=(repo/'scripts/test-sentinel-owned-job.py').read_bytes();text=source.decode();old='bool(k.AssignProcessToJobObject(job,process.process))';assert old in text
mutant=text.replace(old,'True # MUTANT: root not assigned')
f=root/'helper-mutant.py';f.write_bytes(mutant.encode())
r=subprocess.run(['python',str(f),'--repo',str(repo),'--evidence',str(root/'fixture'),'--escape-attempt'],capture_output=True,timeout=30)
(root/'stdout').write_bytes(r.stdout);(root/'stderr').write_bytes(r.stderr)
assert r.returncode!=0 and b'attempted child escaped exact owned Job' in r.stderr,r.stderr
receipt=json.loads((root/'fixture/job-receipt.json').read_text());assert receipt['attempted_child_in_exact_job'] is False and receipt['escaped_child_killed_waited'] and receipt['final_active']==0
(root/'result.json').write_text(json.dumps({'red':True,'exit':r.returncode,'original_sha256':hashlib.sha256(source).hexdigest(),'mutant_sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'receipt':receipt},indent=2))
print('containment mutation red: actual membership false, escaped child killed/waited, Job drained')

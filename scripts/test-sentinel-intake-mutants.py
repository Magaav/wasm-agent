"""Private source copies: no producer source mutation; builds and fixtures retained."""
import argparse,pathlib,shutil,subprocess,json,os,tempfile
p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--evidence',required=True);a=p.parse_args()
repo=pathlib.Path(a.repo).resolve();root=pathlib.Path(a.evidence).resolve();root.mkdir(parents=True,exist_ok=False)
results=[]
for label in ['serial','mutable']:
 tree=root/label
 for crate in ['wa-sentinel','wa-operation','wa-jobs']:
  shutil.copytree(repo/'rust'/crate,tree/'rust'/crate,ignore=shutil.ignore_patterns('target'))
 main=tree/'rust/wa-sentinel/src/main.rs';protocol=tree/'rust/wa-sentinel/src/deploy_protocol.rs'
 if label=='serial':
  source=main.read_text();start=source.index('    // Intake ALL identities');end=source.index('    // The newest upgrade',start)
  # Restore serial dependency: each protocol intake waits behind slow health too.
  source=source[:start]+source[end:];source=source.replace('if preview.get("expected_sha").is_some() {','if preview.get("expected_sha").is_some() {\n            let _=node_activity();')
  main.write_text(source)
 else:
  source=protocol.read_text();assert 'if original != *request' in source
  protocol.write_text(source.replace('if original != *request','if false'))
 env=os.environ.copy();env['CARGO_BUILD_JOBS']='2'
 target=pathlib.Path(tempfile.mkdtemp(prefix='wa-im-'));env['CARGO_TARGET_DIR']=str(target)
 (tree/'target-path.txt').write_text(str(target))
 build=subprocess.run(['cargo','build','--offline','--manifest-path',str(tree/'rust/wa-sentinel/Cargo.toml')],env=env,capture_output=True,timeout=180)
 (tree/'build.stdout').write_bytes(build.stdout);(tree/'build.stderr').write_bytes(build.stderr);assert build.returncode==0
 test=subprocess.run(['python',str(repo/'scripts/test-sentinel-intake-cli.py'),'--sentinel',str(target/'debug/wa-sentinel.exe'),'--evidence',str(tree/'fixture')],capture_output=True,timeout=60)
 (tree/'test.stdout').write_bytes(test.stdout);(tree/'test.stderr').write_bytes(test.stderr)
 assert test.returncode!=0,f'{label} mutant survived'
 expected=b'ack absent at5sec' if label=='serial' else b'concurrent preview mutation not refused'
 assert expected in test.stderr,(label,test.stderr)
 results.append({'mutation':label,'exit':test.returncode,'red':True})
(root/'results.json').write_text(json.dumps(results,indent=2));print(json.dumps(results))
print('sentinel intake mutants ok (2 checks, 0 skipped)')

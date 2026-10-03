"""Private native queue-ack mutant; original source untouched, raw artifacts retained."""
import argparse,pathlib,shutil,subprocess,tempfile,json,os
p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--evidence',required=True);a=p.parse_args();repo=pathlib.Path(a.repo).resolve();root=pathlib.Path(a.evidence).resolve();root.mkdir(parents=True,exist_ok=False)
for crate in ['wa-sentinel','wa-operation','wa-jobs']:shutil.copytree(repo/'rust'/crate,root/'rust'/crate,ignore=shutil.ignore_patterns('target'))
f=root/'rust/wa-sentinel/src/sentinel_return.rs';text=f.read_text();old='if completed || delivery["phase"]=="completed" || ledger["keys"].get(&key).is_some()';assert old in text;f.write_text(text.replace(old,'if emitted>0 || acknowledged'))
target=pathlib.Path(tempfile.mkdtemp(prefix='wa-rt-'));env=os.environ.copy();env.update(CARGO_BUILD_JOBS='2',CARGO_TARGET_DIR=str(target));(root/'target.txt').write_text(str(target))
b=subprocess.run(['cargo','build','--offline','--manifest-path',str(root/'rust/wa-sentinel/Cargo.toml')],env=env,capture_output=True,timeout=180);(root/'build.log').write_bytes(b.stdout+b.stderr);assert b.returncode==0
r=subprocess.run(['node',str(repo/'scripts/test-sentinel-real-parent.cjs'),str(repo/'rust/target/release/wa.exe'),str(target/'debug/wa-sentinel.exe')],cwd=repo,capture_output=True,timeout=100);(root/'fixture.log').write_bytes(r.stdout+r.stderr);assert r.returncode!=0,'queue-ack mutant survived';assert b'elapsed followup carries updating phase' in r.stderr or b'ERR_ASSERTION' in r.stderr,r.stderr
(root/'result.json').write_text(json.dumps({'red':True,'exit':r.returncode}));print('sentinel transition mutant red (1 check, 0 skipped)')

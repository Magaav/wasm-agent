"""Execute exact named normal gate section with actual proof consumer; removal is red."""
import pathlib,subprocess,argparse
p=argparse.ArgumentParser();p.add_argument('--repo',required=True);a=p.parse_args();repo=pathlib.Path(a.repo).resolve()
source=(repo/'scripts/test.sh').read_text()
section=source.split('# BEGIN sentinel-intake required proofs\n',1)[1].split('# END sentinel-intake required proofs',1)[0]
helper=source[source.index('run_proof_fixture() {'):].split('\n}\n',1)[0]+'\n}\n'
preamble='set -e\nGATE_HOME="$(git rev-parse --git-path intake-section)"\nmkdir -p "$GATE_HOME"\nSKIPPED=0\ngate_run(){ "$@"; }\n'
# Enforce required execution, not filenames or source grep.
post='test -f "$INTAKE_PROOF/cli/result.json"\ntest -f "$INTAKE_PROOF/mutants/results.json"\ntest "$SKIPPED" = 0\n'
for label,text,expected in [('normal',section,0),('portable',section,0),('removed',section.replace('run_proof_fixture sentinelIntake 10 python scripts/test-sentinel-intake-cli.py --sentinel "$PWD/rust/wa-sentinel/target/debug/wa-sentinel.exe" --evidence "$INTAKE_PROOF/cli"','true'),1)]:
 if label=='removed':text=text.split('run_proof_fixture sentinelIntakeMutants')[0]
 body=preamble+helper+text+post
 if label=='portable':body=preamble+'unset OS\n'+helper+text+'test "$SKIPPED" = 1\n'
 r=subprocess.run(['C:/Program Files/Git/bin/bash.exe','-c',body],cwd=repo,capture_output=True,timeout=300)
 log=repo/subprocess.check_output(['git','rev-parse','--git-path',f'intake-section-{label}.log'],cwd=repo,text=True).strip()
 log.write_bytes(r.stdout+b'\nSTDERR\n'+r.stderr)
 assert (r.returncode==0)==(expected==0),(label,r.returncode,r.stderr)
print('intake normal consumer passed; removed invocation red; skips=0')

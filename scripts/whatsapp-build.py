"""Frozen Git/source-bound human build. No runtime installation or credentials."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import runpy
import subprocess
import sys
import tarfile

PATHS = ['connectors/whatsapp', 'scripts/whatsapp-stt-local.py', 'scripts/whatsapp-ocr-local.py',
         'scripts/whatsapp-install.py', 'scripts/whatsapp-build.py',
         'scripts/build-whatsapp.sh', 'LICENSE']


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def invoke(args, cwd, env=None, log_prefix=None):
    result=subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if log_prefix:
        path=Path(log_prefix);path.parent.mkdir(parents=True,exist_ok=True)
        path.with_suffix('.stdout').write_bytes(result.stdout)
        path.with_suffix('.stderr').write_bytes(result.stderr)
    result.check_returncode()
    return result.stdout


def source_clean(root, commit=None):
    if invoke(['git', 'status', '--porcelain'], root).strip():
        raise ValueError('clean_committed_source_required')
    head=invoke(['git', 'rev-parse', 'HEAD'],root).decode().strip()
    if commit and head != commit:
        raise ValueError('source_drift_detected')
    return head


def files(root):
    return {p.relative_to(root).as_posix():digest(p) for p in root.rglob('*') if p.is_file()}


def build(root, go, expected_go_sha, python, target_arch="amd64"):
    if target_arch not in ("amd64", "arm64"):
        raise ValueError("target_must_be_amd64_or_arm64")
    root=Path(root).resolve()
    # Interpreter preflight happens BEFORE compilation, even on Linux without `python`.
    if not python or not Path(python).is_absolute() or not Path(python).is_file():
        raise ValueError('absolute_python3_required')
    version=json.loads(invoke([python,'-c','import sys,json; print(json.dumps(list(sys.version_info[:2])))'],root))
    if tuple(version)<(3,9): raise ValueError('python39_or_newer_required')
    if not go or not Path(go).is_absolute() or not Path(go).is_file():
        raise ValueError('absolute_verified_go_required')
    if len(expected_go_sha or '')!=64 or digest(go)!=expected_go_sha:
        raise ValueError('verified_go_executable_hash_required')
    env={**os.environ,'GOTOOLCHAIN':'local','GOWORK':'off','GOFLAGS':'-mod=readonly',
         'CGO_ENABLED':'0','GOOS':'linux','GOARCH':target_arch}
    if invoke([go,'version'],root,env).decode().split()[2]!='go1.27.2':
        raise ValueError('go1272_required')
    commit=source_clean(root)
    tree=invoke(['git','rev-parse',commit+'^{tree}'],root).decode().strip()
    out=root/'target'/('whatsapp-linux-'+target_arch+'-'+tree)
    if out.exists(): raise ValueError('fresh_output_required_preserve_existing_generation')
    out.mkdir(parents=True,mode=0o700)
    frozen=out/'.source';frozen.mkdir(mode=0o700)
    archive=invoke(['git','archive',commit,*PATHS],root)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar.getmembers():
            target=(frozen/member.name).resolve()
            if not target.is_relative_to(frozen.resolve()) or not (member.isfile() or member.isdir()):
                raise ValueError('unsafe_source_archive_member')
        tar.extractall(frozen)
    inputs=files(frozen)
    module=frozen/'connectors/whatsapp'
    invoke([go,'mod','verify'],module,env,out/'.build-logs/module-verify')
    invoke([go,'build','-mod=readonly','-buildvcs=false','-trimpath','-o',out/'wa-whatsapp','.'],module,env,out/'.build-logs/compiler')
    if files(frozen)!=inputs: raise ValueError('frozen_source_drift_detected')
    target=runpy.run_path(str(frozen/'scripts/whatsapp-install.py'))['binary_target'](out/'wa-whatsapp')
    if target['goarch'] != target_arch: raise ValueError('compiled_target_mismatch')
    info=invoke([go,'version','-m',out/'wa-whatsapp'],module,env,out/'.build-logs/binary-build-info').decode()
    settings={line.strip().split('\t',1)[1] for line in info.splitlines() if line.strip().startswith('build\t')}
    if 'GOOS=linux' not in settings or 'GOARCH='+target_arch not in settings:
        raise ValueError('compiled_go_target_unproven')
    invoke([go,'list','-m','-json','all'],module,env,out/'.build-logs/module-graph')
    if files(frozen)!=inputs: raise ValueError('frozen_source_drift_detected')
    source_clean(root,commit)
    for source,name in [('scripts/whatsapp-stt-local.py','whatsapp-stt-local.py'),
                        ('scripts/whatsapp-ocr-local.py','whatsapp-ocr-local.py'),
                        ('scripts/whatsapp-install.py','whatsapp-install.py'),
                        ('connectors/whatsapp/THIRD-PARTY-NOTICES.txt','THIRD-PARTY-NOTICES.txt'),
                        ('LICENSE','LICENSE')]:
        shutil.copyfile(frozen/source,out/name)
        if digest(out/name)!=inputs[source]: raise ValueError('copied_member_drift_detected')
    if files(frozen)!=inputs: raise ValueError('frozen_source_drift_detected')
    source_clean(root,commit)
    manifest={'schema':3,'source':commit,'tree':tree,'platform':'linux-'+target_arch,'target':target,
              'source_files':inputs,'source_binding':'frozen-git-archive+pre-post-hashes',
              'go_executable_sha256':expected_go_sha,'go_version':'go1.27.2',
              'build_logs':files(out/'.build-logs'),
              'files':{n:digest(out/n) for n in ['wa-whatsapp','whatsapp-stt-local.py','whatsapp-ocr-local.py','whatsapp-install.py','THIRD-PARTY-NOTICES.txt','LICENSE']}}
    target=out/'manifest.json'
    with target.open('x',encoding='utf-8',newline='\n') as f:
        json.dump(manifest,f,sort_keys=True,indent=2);f.write('\n')
    return {'bundle':str(out),'manifest_sha256':digest(target),'source':commit,'tree':tree}


if __name__=='__main__':
    try:
        print(json.dumps(build(Path(__file__).resolve().parent.parent,
                               os.environ.get('GO'),os.environ.get('GO_SHA256'),sys.executable,
                               os.environ.get('WA_WHATSAPP_GOARCH','amd64'))))
    except Exception as error:
        # Fixed failure names, no credential-bearing environment/command-line dumps.
        print(json.dumps({'ok':False,'error':str(error) if isinstance(error,ValueError) else 'source_bound_build_failed'}))
        sys.exit(1)

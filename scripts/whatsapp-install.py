"""Human-run, hash-bound per-user Linux artifact installation. Default is dry-run.
Never registers/enables/starts a service; never touches device state or credentials.
"""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def binary_target(path):
    # Inspect bytes, NEVER execute the candidate (including during dry-run).
    with Path(path).open('rb') as stream:
        h = stream.read(64)
    if (len(h) != 64 or h[:7] != b'\x7fELF\x02\x01\x01' or h[7] not in (0, 3)
            or int.from_bytes(h[16:18], 'little') not in (2, 3)
            or int.from_bytes(h[20:24], 'little') != 1
            or int.from_bytes(h[52:54], 'little') != 64):
        raise ValueError('supported_elf64_binary_required')
    machine = int.from_bytes(h[18:20], 'little')
    arch = {62: 'amd64', 183: 'arm64'}.get(machine)
    if not arch:
        raise ValueError('unsupported_binary_architecture')
    return {'goos': 'linux', 'goarch': arch, 'elf_machine': machine}


def admit_target(manifest, binary):
    actual = binary_target(binary)
    if manifest.get('platform') != 'linux-' + actual['goarch']:
        raise ValueError('manifest_binary_architecture_mismatch')
    if manifest['schema'] == 3 and manifest.get('target') != actual:
        raise ValueError('manifest_target_mismatch')
    host = {'x86_64': 'amd64', 'amd64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine().lower())
    if sys.platform != 'linux' or host != actual['goarch']:
        raise ValueError('host_target_mismatch')
    return actual


def install(bundle, expected, prefix, state, python, models, apply=False, ocr_python=None, ocr_models=None):
    ocr_python = ocr_python or python
    if any(not Path(p).is_absolute() for p in (bundle, prefix, state, python, models, ocr_python)):
        raise ValueError("absolute_install_paths_required")
    bundle, prefix, state = map(Path, (bundle, prefix, state))
    manifest_file = bundle / "manifest.json"
    if digest(manifest_file) != expected:
        raise ValueError("manifest_hash_mismatch")
    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    if (manifest.get("schema") not in (2, 3) or manifest.get("platform") not in ("linux-amd64", "linux-arm64")
            or (manifest.get("schema") == 2 and manifest.get("platform") != "linux-amd64")):
        raise ValueError("source_binding_v2_or_v3_required")
    if manifest.get('go_version')!='go1.27.2' or len(manifest.get('go_executable_sha256',''))!=64:
        raise ValueError('pinned_sdk_binding_required')
    source=manifest.get('source','')
    if len(source)!=40 or any(c not in '0123456789abcdef' for c in source):
        raise ValueError('invalid_source_commit')
    inputs=manifest.get('source_files',{})
    required_inputs={'connectors/whatsapp/go.mod','connectors/whatsapp/go.sum','scripts/whatsapp-stt-local.py','scripts/whatsapp-ocr-local.py','scripts/whatsapp-install.py','connectors/whatsapp/THIRD-PARTY-NOTICES.txt','scripts/whatsapp-build.py','scripts/build-whatsapp.sh','LICENSE'}
    if manifest.get('source_binding')!='frozen-git-archive+pre-post-hashes' or not required_inputs.issubset(inputs):
        raise ValueError('incomplete_source_binding')
    if any(not isinstance(v,str) or len(v)!=64 or any(c not in '0123456789abcdef' for c in v) for v in inputs.values()):
        raise ValueError('invalid_source_hash')
    for source,name in [('scripts/whatsapp-stt-local.py','whatsapp-stt-local.py'),('scripts/whatsapp-ocr-local.py','whatsapp-ocr-local.py'),('scripts/whatsapp-install.py','whatsapp-install.py'),('connectors/whatsapp/THIRD-PARTY-NOTICES.txt','THIRD-PARTY-NOTICES.txt'),('LICENSE','LICENSE')]:
        if inputs[source]!=manifest['files'].get(name): raise ValueError('source_member_binding_mismatch')
    tree = manifest["tree"]
    if len(tree) != 40 or any(c not in "0123456789abcdef" for c in tree):
        raise ValueError("invalid_source_tree")
    required = {"wa-whatsapp", "whatsapp-stt-local.py", "whatsapp-ocr-local.py", "whatsapp-install.py", "THIRD-PARTY-NOTICES.txt", "LICENSE"}
    if set(manifest["files"]) != required:
        raise ValueError("unexpected_bundle_members")
    for name, expected_hash in manifest["files"].items():
        path = bundle / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected_hash:
            raise ValueError("artifact_hash_or_ownership_mismatch")
    target = admit_target(manifest, bundle / "wa-whatsapp")
    for path in (prefix, state, Path(python), Path(models), Path(ocr_python)):
        if not path.is_absolute() or any(c in str(path) for c in ('\n', '\r', '"', '%')):
            raise ValueError("unsafe_service_path")
    if ocr_models and (not Path(ocr_models).is_absolute() or any(c in ocr_models for c in ('\n', '\r', '"', '%'))):
        raise ValueError("unsafe_service_path")
    if state == prefix or prefix in state.parents or state in prefix.parents:
        raise ValueError("state_must_be_separate_from_releases")
    release = prefix / "releases" / (tree if manifest["schema"] == 2 else tree + "-" + manifest["platform"])
    # Refuse redirected destination ancestors, not only the final root.
    for destination in (release, state):
        if any(p.is_symlink() for p in (destination, *destination.parents)):
            raise ValueError("symlink_install_destination_refused")
    if release.exists():
        raise ValueError("existing_release_preserved_choose_existing_or_new_source")
    result = {"ok": True, "dry_run": not apply, "source": manifest["source"],
              "tree": tree, "target": target, "host_admitted": True, "release": str(release), "state_untouched": True,
              "service_registered": False, "requested_state_unchanged": True}
    owners = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home()/'.config'))) / 'wa-whatsapp-owners'
    if not owners.is_absolute() or any(c in str(owners) for c in ('\n', '\r', '"', '%')):
        raise ValueError("unsafe_owner_path")
    if not apply:
        return result
    if sys.platform != "linux":
        raise ValueError("linux_apply_only")
    os.umask(0o077)
    release.mkdir(parents=True, mode=0o700)
    for name in required:
        shutil.copyfile(bundle / name, release / name)
        if digest(release / name) != manifest["files"][name]:
            raise ValueError("copied_artifact_hash_mismatch_preserve_partial_release")
        (release / name).chmod(0o700 if name == "wa-whatsapp" else 0o600)
    shutil.copyfile(manifest_file, release / "manifest.json")
    # No state initialization, migration, chmod, volume removal, systemctl or firewall command.
    ocr_models_arg = f' --ocr-models "{ocr_models}"' if ocr_models else ''
    unit = f'''[Unit]
Description=Private WhatsApp linked-device connector ({tree})
After=network-online.target
[Service]
Type=simple
ExecStart="{release / 'wa-whatsapp'}" serve --state "{state}" --owners "{owners}" --python "{python}" --worker "{release / 'whatsapp-stt-local.py'}" --models "{models}" --ocr-python "{ocr_python}" --ocr-worker "{release / 'whatsapp-ocr-local.py'}"{ocr_models_arg}
Restart=on-failure
RestartPreventExitStatus=78
RestartSec=15
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths="{state}" "{owners}"
StandardOutput=null
StandardError=journal
[Install]
WantedBy=default.target
'''
    (release / "wa-whatsapp.service").write_text(unit, encoding="utf-8")
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bundle", required=True)
    p.add_argument("--manifest-sha256", required=True)
    p.add_argument("--prefix", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--python", required=True)
    p.add_argument("--models", required=True)
    p.add_argument("--ocr-python", default=None)
    p.add_argument("--ocr-models", default="")
    p.add_argument("--apply", action="store_true")
    a = p.parse_args()
    print(json.dumps(install(a.bundle, a.manifest_sha256, a.prefix, a.state,
                             a.python, a.models, a.apply, a.ocr_python, a.ocr_models), sort_keys=True))


if __name__ == "__main__":
    main()

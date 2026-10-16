"""Human-run, hash-bound per-user Linux artifact installation. Default is dry-run.
Never registers/enables/starts a service; never touches device state or credentials.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def install(bundle, expected, prefix, state, python, models, apply=False):
    if any(not Path(p).is_absolute() for p in (bundle, prefix, state, python, models)):
        raise ValueError("absolute_install_paths_required")
    bundle, prefix, state = map(Path, (bundle, prefix, state))
    manifest_file = bundle / "manifest.json"
    if digest(manifest_file) != expected:
        raise ValueError("manifest_hash_mismatch")
    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or manifest.get("platform") != "linux-amd64":
        raise ValueError("unsupported_manifest")
    tree = manifest["tree"]
    if len(tree) != 40 or any(c not in "0123456789abcdef" for c in tree):
        raise ValueError("invalid_source_tree")
    required = {"wa-whatsapp", "whatsapp-stt-local.py", "whatsapp-install.py", "THIRD-PARTY-NOTICES.txt"}
    if set(manifest["files"]) != required:
        raise ValueError("unexpected_bundle_members")
    for name, expected_hash in manifest["files"].items():
        path = bundle / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected_hash:
            raise ValueError("artifact_hash_or_ownership_mismatch")
    for path in (prefix, state, Path(python), Path(models)):
        if not path.is_absolute() or any(c in str(path) for c in ('\n', '\r', '"', '%')):
            raise ValueError("unsafe_service_path")
    if state == prefix or prefix in state.parents or state in prefix.parents:
        raise ValueError("state_must_be_separate_from_releases")
    release = prefix / "releases" / tree
    # Refuse redirected destination ancestors, not only the final root.
    for destination in (release, state):
        if any(p.is_symlink() for p in (destination, *destination.parents)):
            raise ValueError("symlink_install_destination_refused")
    if release.exists():
        raise ValueError("existing_release_preserved_choose_existing_or_new_source")
    result = {"ok": True, "dry_run": not apply, "source": manifest["source"],
              "tree": tree, "release": str(release), "state_untouched": True,
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
    unit = f'''[Unit]
Description=Private WhatsApp linked-device connector ({tree})
After=network-online.target
[Service]
Type=simple
ExecStart="{release / 'wa-whatsapp'}" serve --state "{state}" --owners "{owners}" --python "{python}" --worker "{release / 'whatsapp-stt-local.py'}" --models "{models}"
Restart=on-failure
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
    p.add_argument("--apply", action="store_true")
    a = p.parse_args()
    print(json.dumps(install(a.bundle, a.manifest_sha256, a.prefix, a.state,
                             a.python, a.models, a.apply), sort_keys=True))


if __name__ == "__main__":
    main()

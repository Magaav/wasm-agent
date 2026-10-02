import io, subprocess, os, shutil
BS, NL = chr(92), chr(10)
W = "C:/Users/Victor/.wasm-agent/wa-worktree-childdispatcheaf69dde-54cb-4664-84ae-f69916709273"
TMP = "C:/Users/Victor/AppData/Local/Temp/wa-review-eaf6"
def rd(p): return io.open(os.path.join(W,p), encoding='utf-8', newline='').read()
def wr(p,s): io.open(os.path.join(W,p),'w',encoding='utf-8',newline='').write(s)
def run(cmd):
    r = subprocess.run(cmd, shell=True, cwd=W, capture_output=True, text=True, errors='replace')
    return r.returncode, (r.stdout or '')+(r.stderr or '')

MUT = {}
MUT['M-A'] = ('scripts/deploy.sh','bash scripts/test-deploy-record.sh',
  [["> \"$record_tmp\" && mv -f \"$record_tmp\" \"$INSTALL_DIR/installed.txt\"",
    "> \"$INSTALL_DIR/installed.txt\" && true"]])
MUT['M-B'] = ('scripts/upgrade.sh','bash scripts/test-deploy-record.sh',
  [['if [ "$via" = "deploy.sh" ] '+BS, 'if [ "$via" = "deploy.sh-never" ] '+BS]])
MUT['M-C'] = ('scripts/deploy.sh','bash scripts/test-deploy-on-main.sh',
  [['  git merge-base --is-ancestor HEAD origin/main 2>/dev/null '+BS,
    f'  if [ -z "${{WA_INSTALL_DIR:-}}" ] || [ "$REQUIRE_MAIN" = "1" ]; then{NL}  git merge-base --is-ancestor HEAD origin/main 2>/dev/null '+BS],
   ['is not on origin/main; merge it to main and deploy from there - an unmerged deploy leaves main behind the live node"',
    'is not on origin/main; merge it to main and deploy from there - an unmerged deploy leaves main behind the live node"'+NL+'  fi']])
MUT['M-D'] = ('scripts/deploy.sh','bash scripts/test-deploy-gate-policy.sh',
  [['1|true|yes|on) REQUIRE_PROOF=1 ;;'+NL+'esac',
    '1|true|yes|on) REQUIRE_PROOF=1 ;;'+NL+'esac'+NL+'[ -n "${WA_DEPLOY_REQUIRE_RELEASE_PROOF:-}" ] && REQUIRE_PROOF=1']])
MUT['M-E'] = ('scripts/deploy.sh','bash scripts/test-deploy-staging-sweep.sh',
  [[NL+'sweep_stale_staging'+NL, NL+'# sweep_stale_staging   (mutated away: nothing ever looks for residue)'+NL]])
MUT['M-F'] = ('scripts/deploy.sh','bash scripts/test-deploy-staging-sweep.sh',
  [['sweep_stale_staging() {', 'sweep_residue_never() {']])
MUT['M-G'] = ('scripts/verify-install.sh','node scripts/test-verify-install.mjs',
  None)  # special: replace the file with main's version

for label,(path,suite,subs) in MUT.items():
    original = rd(path)
    if subs is None:
        main_ver = subprocess.run(f'git -C "{W}" show e2a86bc:scripts/verify-install.sh', shell=True, capture_output=True, text=True).stdout
        wr(path, main_ver)
    else:
        mutated = original
        ok = True
        for old,new in subs:
            n = mutated.count(old)
            if n != 1:
                print(f"### {label}: ABORT - pattern occurs {n} times"); ok = False; break
            mutated = mutated.replace(old,new)
        if not ok: continue
        wr(path, mutated)
        shutil.copyfile(os.path.join(W,path), os.path.join(TMP,f'{label}-mutated.sh'))
    code,out = run(suite)
    print(f"### {label}  file={path}")
    print(f"    suite={suite}   exit={code}")
    for l in [x for x in out.splitlines() if x.strip()][-3:] if code==0 and 'ALL PASS' in out else []:
        print("      "+l.strip()[:250])
    if not (code==0 and 'ALL PASS' in out):
        keep=[x for x in out.splitlines() if ('FAIL' in x or 'fail' in x.lower() or 'Error' in x or 'error' in x)]
        for l in keep[:4]: print("      "+l.strip()[:250])
        tail=[x for x in out.splitlines() if x.strip()][-2:]
        for l in tail: print("      (tail) "+l.strip()[:250])
    subprocess.run(f'git -C "{W}" checkout -- {path}', shell=True)

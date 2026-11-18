# release-glibc round 3 — two nits from the verification review (verdict: land)
Same worktree/branch (head 3b01caea). Commit locally; never push.
a. Under `curl | bash`, $0 is `bash`, so fleet-install.sh:207 looks for lib/glibc-floor.sh relative to the
   current directory and would SOURCE whatever file is there. fleet-install.sh now carries the check inline:
   remove the relative lib lookup entirely (or only source from the script's own resolved directory when $0 is a
   real file) - a test proves a planted ./lib/glibc-floor.sh in the cwd is never sourced under `bash -s`.
b. The test checks the lib holds exactly one guard block; assert the same for fleet-install.sh.

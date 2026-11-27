# What `wa update` prints and how long it takes - the measurement behind mission update-is-one-line

`update-lines.sh` builds a scratch node (own HOME, own WASM_AGENT_DATA and install directory, stub
sentinel, stub deploy) and drives the REAL `wa update` through it, once on a pipe with every line
timestamped the moment it arrives and once on a pty. The stub deploy writes the shapes a real deploy
writes: `build-status.json`, `sentinel/queue/<id>.json`, `deploy-result.json`, `installed.txt`, and a
`deploy.out` of 7001 lines of which 411 match error|warn|refused|fail - the shape measured on `work`
(7571 lines, 225 alarming) on 25/11.

    measure/update-output/update-lines.sh <case> [lines-in-deploy-out]

cases: `build` (tree install, compile), `published` (tree install, published binary), `fail` (the deploy
fails before the swap), `problems` (installed_with_problems), `current` (the tree already IS the
installed commit), `release-current` (release install, bundle already installed), `release-queued`
(release install, a newer bundle -> systemd-run, which is stubbed so no unit is started).

Every path is scratch; the script refuses, through `scripts/lib/scripts/scratch-home.sh`, to run against
the operator's home. Nothing here touches a network: the fixture's origin is a local bare repository and
`WA_UPDATE_CHECK=0`/`WA_OFFLINE=1` keep the release feed off (except in `current`, whose fast path makes
ONE `git ls-remote` to that local origin - that is the one request the budget allows).

`BEFORE.txt` is the output of the code as it was at the start of this mission (base `70eb209d`);
`NOW.txt` is the output of this branch.

# deploy-prunes-pins-safe

Priority: the safety question of the pin prune, raised by the orchestrator on the first real deploy of
`fc1334f0` (branch `change/deploy-prunes-pins-safe`, from main `3bbf9220`).

## The two answers, measured on this machine

The deploy's own line was `pin prune: 0 removed, 2 kept, 0 left in place in /tmp/wa-deploy-pins (322
process(es) not inspected)`.

**1. Which processes, and why weren't they inspected.** Classified over `/proc` on avell (575 pids at the
time of writing; the deploy's 322 is the same population at that moment):

| class | count | why it could not be inspected | can it be a build? |
| --- | --- | --- | --- |
| kernel threads and zombies | **301** | empty `cmdline`; they have no working directory at all, so `readlink /proc/<pid>/cwd` fails by definition | no - there is nothing running |
| root-owned system daemons | **22** | `/sbin/init`, `/usr/bin/NetworkManager`, `bluetoothd`, `intel_lpmd`, `limine-snapper-watcher`, ... - their `cwd` link is behind `ptrace_may_access`, so a non-root reader gets `EACCES` | possibly (root can write anywhere) |
| other system uids | **8** | `dbus-broker` (uid 81), `polkitd` (102), `systemd-resolved`/`-timesyncd`/`-networkd`/`-udevd` (972-977), `avahi-daemon` (979) | no - they cannot write into a pin we own (0755) |
| our own uid, not dumpable | **3** | `systemd --user` (1136), `(sd-pam)` (1138), `fusermount3` (1706, setuid helper): `dumpable=0`, so even `victor` may not read their cwd | no - but `/proc` alone cannot prove that |

Every process of our uid that *is* inspectable was inspected (240 of the 575 pids had a readable `cwd`,
and every build of this tree runs as our uid). So the population divides into "cannot be a build at all"
(301 + 8) and "an unknown" (22 root daemons + 3 non-dumpable), and the old line added all of them into one
number - which is why it read as a footnote instead of as the open question it was.

**2. What the prune does with a pin when it could not inspect a process.** It keeps it - and not only that
one: **nothing is removed at all**, and the line says which processes and why. Measured live on this branch,
against this node's own pin directory, with no proof supplied:

```
landing-queue: pin prune: 0 removed, 2 kept, 0 left in place in /tmp/wa-deploy-pins 334 process(es) not
  inspected: 301 with no program (kernel threads, zombies), 33 real program(s) - nothing was removed: 33
  process(es) could not be inspected (pid 1 /sbin/init splash; pid 1000 /usr/bin/dbus-broker-launch --scope
  syst; pid 1002 dbus-broker --log 10 --controller 9 --ma), so it cannot be told whether a build runs from a pin
```

The one thing that turns the unknown into an answer is a caller that can prove no build exists: the deploy's
**build lock**, which `scripts/deploy.sh` and `onStale` both claim for their build phase. A build-path deploy
already holds it at that step; a Lua fast-path deploy - the path that never claims it - now takes it for the
prune alone and gives it back. While it is held, no other deploy or onStale build can be running from a pin,
and the line says which lock was the proof (`- no other build can be running (/home/victor/.local/bin/.deploy.lock
(this deploy holds it, so no other deploy or onStale build is running))`). If the lock is busy, nothing is
removed and the line names it: the next deploy prunes.

## What was wrong in `fc1334f0`

`pinProcessUsers` incremented one `uninspected` counter for every unreadable `cwd`, and `pruneDeployPins`
reported that count while removing pins regardless. On a machine with any root daemon - every machine - the
count was never zero, so the line that was meant to be a safety note was permanently printed and permanently
ignored.

## The fix (this branch)

- `pinProcessUsers` classifies instead of adding up: `noProgram` (empty `cmdline`: a kernel thread or a
  zombie) and `programs` (a real program, with its uid and cmdline). A process with an unreadable `cmdline`
  is a program too - an unknown is not an empty one.
- `pruneDeployPins({buildsExcludedBy})`: if there is at least one uninspected **real program** and the caller
  states no proof, every pin is kept and each line says why; `result.blind` carries the first three pids and
  cmdlines, and the human summary prints them.
- `prune-pins --builds-excluded-by <reason>` and the same flag on `pin`: the caller's proof, carried into the
  answer as `builds_excluded_by=`.
- `scripts/deploy.sh`: the lock's names (`DEPLOY_LOCK`, `DEPLOY_LOCK_LOG`, the library) are hoisted above the
  Lua fast-path branch; `DEPLOY_LOCK_HELD=1` after the build branch claims it; step 8b takes the lock for its
  own few hundred milliseconds when the deploy did not, passes that lock as the reason, and releases it.

## Tests

`scripts/test-deploy-pin-prune.mjs`, 80 checks (fast path row `deploy-pin-prune`, gate row in
`scripts/test.sh`), new section 10 `cannotTellKeepsThePin()` on a fixture process root shaped like this
machine's - one real program with no readable `cwd` and its `cmdline`, one kernel thread with an empty
`cmdline`:

- the two are counted separately (`uninspected_programs: 1`, `uninspected_no_program: 1`);
- with no proof, **nothing** is removed and all three pins stay, and the answer names pid 2000;
- the human line says `nothing was removed: 1 process(es) could not be inspected (pid 2000 ...)`;
- with `--builds-excluded-by`, the prune goes ahead and removes down to the kept set, and the answer carries
  the reason;
- a process with no program does not block the prune on its own.

The pin step's own command line is now asserted flag by flag (`--pin-dir`, `--install-dir`,
`--builds-excluded-by`, `--wait-timeout`, `--json`) instead of as one exact substring - stronger, not weaker:
a dropped flag fails. `bash scripts/test-discriminates.sh origin/main`: `discriminates`, failing on the old
code at `the unknowable process is counted as a real program, the kernel thread is not`.

## Residual limits, named

- A **root** build started by hand inside a pin (`sudo cargo build` from `/tmp/wa-deploy-pins/<sha>`) is
  invisible to this code: `/proc/<pid>/cwd` of a root process cannot be read by us. It is excluded only by
  the lock proof, and the lock binds `deploy.sh` and `onStale`, not a hand-run command. Every build this
  project starts goes through those two.
- A process of another uid cannot write into a pin (the directory is ours, mode 0755), so it cannot be
  building from one; it is counted as a real program by the classifier because `/proc` cannot tell us what it
  is doing, and it is only ruled out by the proof.
- The classification reads `cmdline` and `status`, which are world-readable for exactly the processes whose
  `cwd` is not; a process that hides both is still an unknown, and unknown keeps the pin.

## Texts to approve

1. `pin prune: <r> removed, <k> kept, <f> left in place in <dir> <N> process(es) not inspected: <M> with no
   program (kernel threads, zombies), <K> real program(s)`
2. `pin prune: ... - nothing was removed: <K> process(es) could not be inspected (pid <p> <cmd>; pid <p>
   <cmd>; pid <p> <cmd>), so it cannot be told whether a build runs from a pin`
3. `pin prune: ... - no other build can be running (<lock path> (this deploy holds it, so no other deploy or
   onStale build is running))` - or `(taken for this prune alone, so no build is running from a pin)`
4. `pin prune: another build holds <lock>, so nothing was removed - a pin it may be building from is kept, and
   the next deploy prunes`
5. `pin prune: <kept|kept>: <sha12> (<K> process(es) could not be inspected and no lock proves no build is
   running, so nothing was removed)` - the per-pin line in that state

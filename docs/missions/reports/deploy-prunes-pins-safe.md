# deploy-prunes-pins-safe

Branch `change/deploy-prunes-pins-safe` from main `3bbf9220`. The safety question raised by the first real
deploy of `fc1334f0`, whose line was `pin prune: 0 removed, 2 kept, 0 left in place in /tmp/wa-deploy-pins
(322 process(es) not inspected)` - a number that was printed on every run and explained nothing.

## The two answers, measured on this machine

**1. Which processes, and why weren't they inspected.** Every pid whose `/proc/<pid>/cwd` link a non-root
reader may not follow. Classified over `/proc` on avell (575 pids at the time of writing; the deploy's 322
is the same population at that moment):

| class | count | why the cwd is unreadable | is it a build of ours? |
| --- | --- | --- | --- |
| kernel threads and zombies | **301** | empty `cmdline`; they have no working directory at all | no - no program is running |
| other users' real programs | **30** | `ptrace_may_access`: `/sbin/init`, `NetworkManager`, `dbus-broker` (uid 81), `polkitd` (102), `systemd-resolved`/`-timesyncd`/`-networkd`/`-udevd` (972-977), `avahi-daemon` (979) | no - the pins are ours, mode 0755, so another user cannot build in one |
| **this user's real programs** | **3** | `systemd --user` (1136), `(sd-pam)` (1138), `fusermount3` (1706, a setuid helper): `dumpable=0`, so even `victor` may not look | no - but the code cannot prove that from `/proc` |

A build of this tree runs as this user, and this user's processes are readable - so the third row is the one
that means "cannot tell", and the other two are facts with an answer. The old line added all 334 into one
number, which is why it read as a hole.

**2. What the prune does with a pin when it could not inspect a process.** A pid **of this user** that could
not be inspected stops the removal: nothing is removed, and the line names the pid. Measured live on this
branch, against this node's own pin directory, with no proof supplied:

```
landing-queue: pin prune: 0 removed, 2 kept, 0 left in place in /tmp/wa-deploy-pins (3 process(es) of this
  user not inspected, 30 process(es) of other users not inspected, 300 with no program (kernel threads,
  zombies)) - nothing was removed: 3 process(es) of this user could not be inspected (pid 1136
  /usr/lib/systemd/systemd --user; pid 1138 (sd-pam); pid 1706 fusermount3 -o rw,nosuid,nodev,fsname=po), so
  it cannot be told whether a build runs from a pin
```

The one thing that turns that unknown into an answer is a caller that can prove no build is running: the
deploy's **build lock**, which `scripts/deploy.sh` and `onStale` both claim for their build phase. A build-path
deploy holds it at that step already; a Lua fast-path deploy - the path that never claims it - takes it for
the prune alone and gives it back. The line then says which lock was the proof, or that the lock was busy and
nothing was removed.

This is also what the first real removal was judged by: the deploy of `f05b3150` printed `removed
899fdd47caee`, and a scan afterwards found no process with `exe` or `cwd` under that tree.

## The fix (this branch)

- **The count is split** by what it means: `uninspected_own` (this uid), `uninspected_others` (other uids),
  `uninspected_no_program` (kernel threads and zombies).
- **Only this uid's uninspectable process stops the removal** (`pruneDeployPins`'s `blind`): every pin is kept
  and each line says why; `blind` carries the first three pids and cmdlines into the answer. Another user's
  process is reported as `N process(es) of other users not inspected` and is out of scope.
- **A pin is in use when a process's `cwd` OR its `exe` is under it.** A test binary started out of the
  pinned target dir has its cwd elsewhere and its exe right there; the reason line says which (`cwd <path>` /
  `exe <path>`), and a Linux ` (deleted)` suffix is stripped before the comparison.
- **`--builds-excluded-by <reason>`** is the caller's proof that no build can be running; `scripts/deploy.sh`
  passes the deploy lock (it holds it on the build path), and on the Lua fast-path it takes that lock for the
  prune alone - so the proof is a fact there too, and is given back. The lock's names are hoisted above the
  Lua fast-path branch for exactly this (that branch never claimed it).

## Tests

`scripts/test-deploy-pin-prune.mjs`, **86 checks** (fast path row `deploy-pin-prune`; gate row in
`scripts/test.sh`), section 10 on fixture process roots shaped like this machine's:

- one real program of THIS uid with no readable cwd, one of another uid, one kernel thread: the three counts
  are separate (`1 / 1 / 1`), nothing is removed, the pid of ours is named, and the human line reads `1
  process(es) of this user not inspected, 1 process(es) of other users not inspected, 1 with no program`;
- the same tree with `--builds-excluded-by`: the prune goes ahead and removes down to the kept set, and the
  answer carries the reason;
- another user's process alone (plus a kernel thread) does **not** stop the prune, and is reported by name;
- a process whose `cwd` is outside a pin and whose `exe` is `<pin>/target/probe-binary` keeps that pin, with
  the reason naming the exe - and removing that process makes the same call remove the pin.

`bash scripts/test-discriminates.sh origin/main`: `discriminates` (it fails on the old code at the
classification assertion). Also re-run green on this branch: `test-deploy-luafast-record.sh` (it extracts a
neighbouring block of the same file), `test-deploy-policy-order.sh`, `test-deploy-ship.sh`,
`test-deploy-lock.sh` (the lock is now named on every path), `check-deploy-shipped.mjs` (190 checks),
`check-temp-retention.mjs`.

## Residual risk, named

A **root** process sitting in a pin (`sudo cargo build` started by hand from `/tmp/wa-deploy-pins/<sha>`) is
invisible: a non-root reader may not follow its `cwd` or `exe`. It is excluded only by the lock proof, which
binds `deploy.sh` and `onStale` - every build this project starts - and not a hand-run command. Recorded
here rather than hidden in a count.

## Texts to approve

1. `pin prune: <r> removed, <k> kept, <f> left in place in <dir> (<N> process(es) of this user not inspected,
   <M> process(es) of other users not inspected, <P> with no program (kernel threads, zombies))` - each part
   printed only when it is not zero
2. `pin prune: ... - nothing was removed: <N> process(es) of this user could not be inspected (pid <p> <cmd>;
   pid <p> <cmd>; pid <p> <cmd>), so it cannot be told whether a build runs from a pin`
3. `pin prune: ... - no other build can be running (<lock path> (this deploy holds it, so no other deploy or
   onStale build is running))` or `(taken for this prune alone, so no build is running from a pin)`
4. `pin prune: another build holds <lock>, so nothing was removed - a pin it may be building from is kept, and
   the next deploy prunes`
5. `pin prune: kept <sha12> (a live process is inside it (pid <pid>, cwd <path>))` and the same with
   `exe <path>`

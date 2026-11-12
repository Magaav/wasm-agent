# Scripted runs: `wa chat` without a terminal, and steering a run that is already going

Two things a launcher needs and did not have: a `wa chat` it can wait for, and a way to say something
to a run that is already in flight.

## The measured night

2026-11-11, orchestrators and scheduled tasks on this fleet:

- `wa chat "<prompt>" > log 2>&1` ran its turn, wrote the answer, and then sat at the REPL prompt for
  ever, because its stdin was not a terminal and nothing was ever going to arrive on it. Five kills in
  one night on one node.
- Each kill left the session looking live: the next `wa resume` was refused `resource_busy`, because
  nothing had released the claim in an orderly way. And the only lever an orchestrator had to correct a
  run in flight was the same kill, so correcting a run meant destroying it.

## What a scripted run is

The mode is decided from the one fact that describes it - `host.isatty("stdin")` - and an explicit
`--once` (or `-p`, `--print`) says the same thing for a caller whose stdin *is* a terminal:

```
wa chat "summarise the last landing" > answer.txt      # stdin not a terminal: one turn, then exit
x | wa chat                                            # turns from the pipe, exit at its end
wa chat --session <id> --once "next step"              # explicit, whatever stdin is
wa resume --session <id>                               # same path: no prompt, stdin read to its end
```

A scripted run:

- runs the turn it was given (then each non-empty line still on stdin, when the command line carried no
  prompt - a caller that passed its prompt as an argument is never made to wait on a stream it may not
  close);
- starts **no** stdin reader thread (`lua/core/cli_input.lua`, `read = false`): the host thread would sit
  on that stream for the life of the process, which is the leak;
- prints no banner, no prompt row and no transcript replay, and skips the update check: stdout is the
  run's own output, so `$(wa chat --once ...)` is the answer and not a screen;
- says `wa: session <id> ok|failed` on **stderr**, so a caller capturing stdout still learns which
  session to resume or steer;
- releases the session on the way out (`agent:close()`: the presence row and the conversation row go, and
  each run releases its own resource claim on every exit path - `lua/core/agent.lua`), which is the
  orderly version of the kill;
- exits with the last turn's status: `0` when every turn answered, `1` when one failed.

A reader at a terminal gets exactly what they had: the detection is `== false`, so a binary that cannot
answer `host.isatty` (an older one) is treated as interactive.

## Steering a run without killing it

The durable inbox already existed (`lua/core/steering.lua`, `steering_inbox`): a queued note is consumed
by the run that owns the session at its next context boundary, atomically with its read receipt, and it
lands in the transcript as a user row. What did not exist was a shell door to it - it was reachable from
a model turn (`subagent`'s `steer_session`) and from the window, i.e. not from the orchestrator that is
not in a turn.

```
wa steer <session> "<note>"        # queue it for the run in flight
wa steer <session> --status        # the run and its receipts (queued / read / deferred)
wa steer <session> --status --json
steer: queued 9b0e… for run 4c1a… (at its next context boundary)
```

- **Durable before delivered.** The row is written, then the run reads it. `queued` means accepted into a
  run that is in flight - *read means durable context, not verified compliance*, which is the receipt's
  own wording.
- **Refused honestly when there is nothing to deliver to.** A session between turns has no active run:
  `steer: no_active_steering_target` (exit 1), naming the last run's state and pointing at
  `wa chat --session <id> --once "<note>"`. A note that goes nowhere is worse than a refusal.
- **Cross-process, which needed a fix.** `steering.recover` used to treat a run row written by *another
  process instance* as interrupted - every process has its own `boot_id` - so a steer from a shell was
  refused on a session that was plainly running. It now asks the question the project already asks about
  a claim: is a process serving this session? (`session_presence`, pid + boot + a heartbeat refreshed at
  every round boundary, with a tool call's tolerance). Only when nothing is serving it is the run marked
  `unknown` and its queued notes deferred - never replayed.
- **The owner is the session's own user**, so the ownership check inside `steering.control` is the real
  one: this door cannot steer a session that is not this user's, and it cannot write to the transcript
  itself - only the run does that.

## What it is not

- `wa steer` is not a second queue and does not create a run: with no run in flight it refuses, it does
  not start one (`wa chat --session <id> --once "<note>"` is how you give it a turn).
- A scripted run is still one session with one transcript: `--once` ends the *process*, not the thread -
  `wa sessions` and `wa chat --session <id>` find it as they always did.
- Watching is still read-only (`docs/SESSION-WATCH.md`): `wa watch` follows a session and `wa steer`
  writes to it, and they are deliberately different commands with different authorities.

## Evidence

`scripts/test-cli-scripted.mjs` (wired into `scripts/fast.sh` with `WA_BIN`) drives a real `wa` process
against a local SSE provider fixture and proves, in one run (~5 s): a scripted run exits by itself with
its run's status; a stdin nobody closes does not hold it; the answer is on stdout and the session id on
stderr; the process leaves no presence row and the next run of the same session is not refused; a note
queued with `wa steer` from another process reaches the run at its next context boundary and is in the
transcript as a read inbox row; a pipe of lines becomes turns; and `wa steer` refuses a session with no
run in flight, an unknown session, and a missing session id (each by name, with its own exit code).

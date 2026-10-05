# NEEDS_CHANGE — independent exact-source focused review

Producer 66296cf798aa92a2a73787626d742840fc6b3510, tree cf42b6d042493bef0674f146227a4011e52fce38, base 565d169. Own tree fast-forwarded to exact producer; no production edits or backend integration.

## Reproduced defect
ui/app.js:388-389 only disables `follow` for messages on wheel/touch. For a wa-agent-session transcript it releases the anchor but retains global follow=true. Subsequent delta -> pin(), lines 413-415, jumps child to bottom. Private real headless child-probe.js: before=0, after=4975, follow=true; probe FAIL, wrapper exit 1, Chrome exit 0. This uses actual wa-agent-session and actual handleEvent/pin, but explicitly selects transcript as the producer's own child test does; complete native child transport integration not tested. Producer test-final-answer-ui.js:107-109 only tests anchor removal, not subsequent growth preserving child position. Falsifiable requirement: wheel/touch/manual/key release followed by child delta/reply must retain that child's position without changing main/sibling.

## Executed evidence
scripts/test-ui.ps1 exit 0: reload,startup-recovery,inspect-window,view-window (four stages).
Source-root WA_SCRIPT test-final-answer.lua exit 0: 9 checks.
Source-root actual agent-loop test-final-answer-loop.lua exit 0: 55 checks, 0 skips. Private home/database; fake HTTP and forbidden host.http/http_stream. Captured run identities non-null (agent.lua sets self.run_id at 1029); no nil-equality reliance observed.
test-final-answer-browser.mjs exit 0, Chrome exit 0, nonempty pass probe. Pixel and lifecycle assertions execute.
Private copied assertion mutation inverted wheel release assertion: exit 1, nonempty FAIL `MUTATION wheel must retain anchor`. Production files never mutated; original probe retained.
Screenshot browser/observation/screenshot.png visually inspected: Race heading and long evidence visible in narrow assistant bubble; composer remains visible. It is not a screenshot of settled activity collapse and does not prove all acceptance appearance claims.
All foreground operations settled with closed output streams.

## Limits and coverage gaps
No full gate, provider inference/timing, network provider, deployment, main movement, push, installation, restart, live configs, registry/bootstrap or rejected backend effects. gate_verified:false; release_verified:false. Targeted lookup tested only isolated UI mock contract, not combined wiring.
No test-final-answer references found in scripts/test.sh, scripts/test-windows.ps1 or scripts/test-ui.ps1: focused fixtures are manually reachable, not routine suite coverage. Pi bridge regression was not executed.
Four commit diffs retained in commits.diff; source inspection covered changed wire/UI/test paths, but complete all-callers/graph and all acceptance cases were NOT completed. This is a negative focused review, not a certificate of remaining behavior. Followup fixture overrides bot.steer and provider.complete_with, so it proves selected deterministic loop continuation, not complete provider selection/auth transport behavior.
Raw logs, events, browser DOM/screenshots and mutation retained here. hashes.sha256 records artifact hashes. No production patch proposed.

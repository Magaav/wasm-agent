# Graph patch-impact trial

The graph is an **omission detector**, not a navigator that every run must use and not a
certificate that a patch is correct. `WA_GRAPH_PATCH_AUDIT=1` enables an automatic
audit when an operator run with native `write`/`edit` changes or a shell-using run
first attempts to finish. A resolved call from another file into a changed definition becomes a
review lead if that file was not read with native `read`/`read_many` in this run.
The agent gets an audit follow-up step to inspect the lead and revise the patch.
It is asked to record `graph {action:"audit_assess",grade:0..3,reason:"...",
critique:"...",evidence:"..."}` after that inspection. Grades mean 0 irrelevant/noisy,
1 related but no new information, 2 useful check/confirmation, and 3 prompted a
patch or test revision. The reason should cite what it inspected; the critique
should name a limitation or say none was observed. This is a bounded model
self-report, not operator verification, and it cannot set `worthy`.
If the agent omits it, it gets one bounded reminder; a second omission is reported
as missing rather than silently assigned a grade.
The final answer says when leads, gaps, or audit errors remain.

The native `graph {action:"audit"}` verb can run the same check on demand;
`source:"git"` audits the current Git working-tree patch (staged and unstaged).
A standard `git commit` issued through the `bash` tool is checked before the
command runs: if it has unread leads, the first attempt returns them without
committing. A repeated attempt with the same patch can acknowledge a false
positive. This is a soft review prompt, not a security boundary or universal
commit hook; commits hidden in scripts/other tools are not intercepted. It
synchronously reindexes before evaluating the patch, then checks for source
changes again. `WA_GRAPH_WATCH=0` can remove the always-on watcher cost in an
audit-only trial; the audit still refreshes itself. Do not disable the watcher
for navigation on an older node whose ordinary graph reads lack source-freshness
checks.

## What is and is not observed

- The audit maps changed **current-file lines** to enclosing syntax definitions,
  then follows only resolved incoming `calls` edges. It cites the exact call site.
  Parser-proven blank and comment-only lines remain in `changed_lines` but are
  reported separately as `ignored_lines`; they are not dependency coverage gaps.
  A line containing code plus a trailing comment remains semantic.
- A top-level edit, unsupported file, unrecorded/large patch, deleted file, or
  line with no matching definition is an explicit coverage gap. Dynamic calls,
  reflective dispatch, unresolved edges, and behavior changes with no call edge
  are outside this check even when no gap is reported.
- `bash`/shell edits are not captured by the run's reversible changeset, but
  Git's current patch supplies line anchors for tracked files. Untracked code
  files are treated as whole-file changes. The Git mode may also include
  pre-existing changes from other runs, so its leads are not attributed to this
  one. Reads through shell, grep, earlier runs, or another worker are not
  counted as native-read evidence. Accordingly, "unread" means only "not
  observed through native read tools in this run."
- The audit does not permanently block a commit. It reports leads and uncertainty so the
  agent and operator can inspect them before retrying. Source can change concurrently after
  the check; the graph does not make the patch atomic.

## The 48-hour keep/remove signal

After enabling the flag on the deployed node, use `graph
{action:"audit_report",hours:48}`. `ready_for_review` turns true 48 hours
after the **first recorded audit**, not 48 hours after a code merge. The report
shows audit count, leads, coverage gaps, audit milliseconds, maximum graph DB
size, and any extra model time/tokens after a lead. `self_assessment` gives the
grade distribution, bounded reasons/critiques, and the number of follow-up steps
with no assessment. Read those as the agent's qualitative experience, not proof
of a prevented mistake. An observed native read and
subsequent patch revision sets `patch_changed_after_lead`: it is a candidate for
review, **not proof** the graph helped. A shell-based follow-up may be invisible.

For a concrete run, inspect its transcript and final patch. Only when a graph
lead caused a real correction that the initial patch missed should the operator
record `graph {action:"audit_feedback",run_id:"...",outcome:"confirmed_catch",
commit:"..."}`. Use `false_positive` when a lead was irrelevant; otherwise
`unresolved`. The tool refuses feedback for runs with no graph lead. The report's
`worthy` field stays `unproven` until at least one operator-confirmed catch;
this is an evidence flag, not an automatic scientific claim of causality.

At 48 hours, keep the graph only if confirmed catches justify its audit and
continuation cost. If too few code patches were audited, extend the window
(`hours` accepts up to 720). If leads are noisy or no corrections are confirmed
after an adequate sample, remove the runtime graph and preserve the trial data.

Reports are phase-aware. Events from the original trial have no explicit tag and
are classified as `phase_1`; the current runtime emits `phase_2`. The report's
top-level counts cover the requested window, while `phases` splits the same
events and `current_phase_started_at` begins with the first Phase 2 audit. The
48-hour `ready_for_review` clock applies to the current phase.

The always-on watcher is a potential waste: it scans and hashes the indexed
source tree after source change events even when no agent queries the graph.
This implementation adds no new daemon. The audit's two synchronous scans are
timed in telemetry; `WA_GRAPH_WATCH=0` is available for the audit-only trial.
No memory leak has been established by this code review or the model-free tests.

# ready-hint - target-is-what-installs, the retry hint's /update lead (Fable, 24/11)

One commit on top of the reviewed branch `change/target-is-what-installs` (base `origin/main` `65e3daef`,
`origin/main` has since moved to `4bceddd5`; not rebased, not merged). Nothing rewritten: the four reviewed
commits are untouched, this one is appended. Nothing pushed, nothing installed, no live node touched.

## The commit

| commit | what |
| --- | --- |
| `f2a7621d` | `installer_outcome::retry_hint`: a request `/update` wrote is re-asked with the verb the person used |

Measured first, so the branch condition is a fact and not a guess: `/update` prefixes its own reason -
`lua/core/update.lua:475` returns `"/update: deploy " .. where .. " through the gate"` and `:860` prefixes an
operator's own text with `"/update: "`. `retry_hint` therefore looks at the reason it is handed: a reason
starting with `/update` gets

> `run wa update again (or: wa-sentinel request deploy --reason '{reason}'{ --expected-sha <sha>}) - <why>`

and any other reason keeps `re-request with: wa-sentinel request deploy --reason '{reason}'...` - the door a
script uses. The `--expected-sha` rule is unchanged (`0500a2c3`/`e5f8813b`: offered only when a deploy would
still take that commit), and the three explanations that follow the command are the same words as before.

Composed and observed (`cargo test --offline --manifest-path rust/wa-sentinel/Cargo.toml
installer_outcome_tests::the_retry_hint -- --test-threads=1 --nocapture`):

```
retry hint for a /update request: the installer ended and nothing was installed: deploy: refused(component_proof_failed): nothing installed; it is re-queued automatically once, when this node is next quiet; run wa update again (or: wa-sentinel request deploy --reason '/update: deploy /srv/tree through the gate' --expected-sha 15465eec3345f7dc56751654e29b293cef05f3e5) - that commit is still exactly origin/main, so deploy.sh accepts it
```

## The row (updated, not replaced)

`installer_outcome_tests::the_retry_hint_never_offers_a_commit_deploy_sh_would_refuse` keeps its four cases and
gains a fifth, which is the one this tweak is about:

```
    // 5. A REQUEST /update WROTE IS RE-ASKED WITH THE VERB THE PERSON USED (Fable, 24/11): /update prefixes its
    // own reason ("/update: …", lua/core/update.lua:475 and :860), so the hint leads with `wa update again` and
    // names the sentinel's door second. A person must not be handed the internal verb first.
    let detail = refuse("1795475320000000000-4242-00000000000000000014", json!({"verb": "deploy",
        "id": "1795475320000000000-4242-00000000000000000014", "queued_at": 1795475320u64,
        "expected_sha": later, "reason": "/update: deploy /srv/tree through the gate"}));
    assert!(detail.contains("run wa update again (or: wa-sentinel request deploy --reason '/update: deploy /srv/tree through the gate' --expected-sha "),
        "the product verb leads, and the sentinel's door follows it: {detail}");
    assert!(!detail.contains("re-request with:"), "and the internal verb is never the lead: {detail}");
```

Row output (`cargo test … installer_outcome -- --test-threads=1`, under `flock -o ~/Work/missions/.suite.lock`):

```
test installer_outcome_tests::a_record_and_a_request_naming_the_same_commit_at_different_lengths_are_installed ... ok
test installer_outcome_tests::a_record_naming_the_advisory_is_not_the_demanded_install ... ok
test installer_outcome_tests::a_refused_installer_is_a_failure_with_its_own_sentence ... ok
test installer_outcome_tests::a_request_without_a_commit_claims_nothing ... ok
test installer_outcome_tests::a_spawned_installer_that_ended_without_a_verdict_fails_and_requeues_once ... ok
test installer_outcome_tests::an_earlier_installers_success_is_not_this_requests ... ok
test installer_outcome_tests::an_expected_sha_outranks_the_recorded_target ... ok
test installer_outcome_tests::an_install_that_reached_the_record_is_installed ... ok
test installer_outcome_tests::an_installer_with_no_terminal_line_is_still_running ... ok
test installer_outcome_tests::the_retry_hint_never_offers_a_commit_deploy_sh_would_refuse ... ok

test result: ok. 10 passed; 0 failed; 0 ignored; 0 measured; 159 filtered out; finished in 0.07s
```

Whole crate, after the change: **169 passed / 169** (`cargo test --offline --manifest-path
rust/wa-sentinel/Cargo.toml -- --test-threads=1`, 34.07 s, under the suite lock).

The row is still RED on the base for the reason `1f191811` recorded (the base has no `retry_hint` and offered the
recorded target as `--expected-sha`); this commit adds a case to it, it does not weaken one - the two new
assertions require the `/update` form to LEAD with `wa update again` and forbid `re-request with:` anywhere in
that hint.

## Texts to approve (verbatim, the ones this commit changes)

1. `run wa update again (or: wa-sentinel request deploy --reason '{reason}' --expected-sha {expected}) - that commit is still exactly origin/main, so deploy.sh accepts it`
2. `run wa update again (or: wa-sentinel request deploy --reason '{reason}') - no --expected-sha: this request demanded no commit, and a commit it only recorded when it was written is not a pin deploy.sh would accept`
3. `run wa update again (or: wa-sentinel request deploy --reason '{reason}') - no --expected-sha: the commit it demanded is not exactly origin/main now, and deploy.sh refuses an expected SHA that is not`
4. the three `re-request with: wa-sentinel request deploy …` lines lose their parentheses and keep their words
   (`docs/missions/reports/target-is-what-installs.md`, "Texts to approve" 3-6, has all of them with the composed
   example).

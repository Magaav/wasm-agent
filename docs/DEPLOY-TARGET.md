# What a deploy installs, and what a request records

One statement, two readers. `scripts/deploy.sh` rule 2 decides what may be installed; the sentinel's
`deploy_protocol::target_commit_at` (`rust/wa-sentinel/src/deploy_protocol.rs`) records what a request is
asking for. Both cite the statement below, and a test reads this file and both citations
(`publish_loop_tests.rs`, `the_target_rule_is_stated_once_and_both_halves_cite_it`), so the two cannot drift
back into carrying their own idea of "main".

MEASURED 24/11 on `work`: the checkout names a `host` git bundle as a source of main
(`git config wa.deployRemote host`), and that bundle's main was `74d48431`, seven days behind
`origin/main`. The sentinel recorded the bundle's tip as the target of EVERY request it wrote, while
`deploy.sh` built `HEAD` and installed `345e51be`. The installs were right, and everything that spoke by the
recorded target said the wrong commit: the installer verdict, the pause line's "(target commit ...)", and a
retry hint (`--expected-sha 74d48431`) that `deploy.sh` refuses by rule 2's tail.

## The rule

> A deploy installs **HEAD** of the tree it builds, and only when HEAD is on a named main and behind none of
> them. The named mains are `origin/main` and the main of each `wa.deployRemote` remote that this checkout
> can resolve. A tree behind any of them is refused, and a tree whose HEAD is on none of them is refused.
> A request records **HEAD** when that rule would accept it, and **origin/main** otherwise: never a named
> remote's main, and never a main that is behind `origin/main`.

## Where each half lives, and the two places it is weaker on purpose

* `scripts/deploy.sh` rule 2 builds the set (`MAIN_REFS`), **fetches** each remote, refuses a tree behind
  any of them, and refuses a tree whose HEAD is on none of them; the commit it installs is `HEAD`.
* `deploy_protocol::target_commit_at` builds the same set from the refs this checkout already has - **no
  fetch**, because a request must not make a network call to be written - and records `HEAD` when HEAD is on
  one of them and behind none of them, `origin/main` otherwise. A question it cannot answer (an unreadable
  ref, a shallow history) is not a yes: it falls back to `origin/main` rather than recording a commit
  `deploy.sh` would refuse.
* With no readable main ref at all, `deploy.sh`'s rule 2 does not run and it would build HEAD unchecked.
  The sentinel does not mirror that: it records `origin/main` or, when even that cannot be read, records
  nothing and says so. A request with no recorded target claims nothing.

The recorded target is advisory, never authority: `deploy.sh` revalidates the source SHA before building and
before swapping, and a request that carries `--expected-sha` is judged by THAT commit
(`rust/wa-sentinel/src/installer_outcome.rs`), never by the advisory one it recorded at request time.

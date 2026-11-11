# Model-less nodes

A node can be **declared** to have no model. It keeps doing everything else - serving the fabric,
hosting services and connectors, holding other nodes' sessions and answering their requests - but it
refuses to start an agent turn, with a named reason, instead of producing one it cannot serve.

## Why a declaration, and not just "unconfigured"

`provider.configured()` already answers "does this node have a base URL, a key and a model". It is the
wrong question here. A node whose provider answers **401** is fully configured: the turn starts, the
request fails, and the turn ends with an empty reply. Nothing in the transcript says a model was never
consulted. Measured on openclaw, 4-11 November 2026: **three turns in seven days**, all empty, from
exactly this case - two test pings and one Sentinel deploy-notice wake. A wake that produces an empty
turn looks *handled*.

So model-less is a fact the operator states, not an inference from a missing key. It can be said
before the first failure, and it survives a restart.

## The declaration

Persisted under the node's state directory as `model-less`, or forced by `WASM_AGENT_MODEL_LESS=1`.

| Value | Meaning |
| --- | --- |
| `1` `true` `yes` `on` | model-less |
| `0` `false` `no` `off` | not model-less, **stated** (survives a restart with that meaning) |
| absent | not declared: use the environment, then the default |
| anything else | not a declaration: refused, never read as "no" |

Precedence: **state file, then environment, then default (`false`)**. The persisted decision wins over
the environment on purpose - a unit file left over from before the decision must not overrule the file
written after it.

`provider.set_model_less(on, revision)` writes it (revision-checked like every other selection);
`provider.model_less()` reads it and returns `(value, source)`; `provider.model_less_refusal()` returns
the one refusal shape the turn, the transcript and `/health` share. The capability router accepts
`set_model_less` with `on` and `revision`, so a coordinator can declare a node it cannot shell into.
No key is read, moved or printed by any of this.

## The refusal

The check sits in `Agent:run` **before** the `local_run` fallback. That ordering is the feature:
`local_run` answers from memory and returns a reply shaped exactly like a model answer, so a refusal
placed after it would still produce a plausible turn. The refusal instead:

* returns and emits `this node is declared model-less (<source>) - No agent turn can run here: ...`;
* records the turn in the transcript with `ok = false`, so "nothing ran" cannot be read as "the model
  had nothing to say";
* emits a `status` event naming the refusal (`turn refused: node_model_less`);
* never calls the provider.

`/health` reports `model_less`, which can be `true` while `configured` is also `true` - that pair is
precisely the node this exists for. `wa status` shows `model-less=yes (no turn can run here)`.

## What is not done here

Routing a wake that belongs to *another* node away from a model-less node - so a Sentinel or
deploy-return notice for a session owned elsewhere is delivered to the owning/requesting node rather
than refused here - is **not implemented**. Today such a wake is refused visibly, which is strictly
better than an empty turn, but it still costs the requester a failed wake instead of a delivery. The
sentinel's notice path is where that belongs, and it is not in `lua/core/selfloop.lua`.

## Verification

`scripts/test-model-less.lua` (in the fast path) covers the precedence table, the invalid value, the
clear, the refusal shape, and one **real turn** on a declared node: the provider stub is asserted
never to be called, the reply is asserted to name the reason and not to be the memory fallback, and
the transcript is asserted to hold it. Disabling the branch makes the turn fall through to HTTP and
the test fails, so it is not a vacuous check.

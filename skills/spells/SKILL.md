---
name: spells
description: >-
  Turning repeatable work into verified spells and keeping them healthy. Load it before
  saving, composing, repairing or retiring a spell, when a skill's deterministic sequence
  keeps recurring, or when a spell fails.
---

# Spells

A spell is deterministic, verified execution: steps plus a mandatory `post` that settles the
effect. The contract is `docs/SPELLS.md`; the skill-evolution procedure is `docs/SKILLS.md`.

- **Crystallize.** While using any skill, turn a repeatable deterministic sequence into a
  verified spell (`spell_save`), then refactor the skill to call it. Verify the postconditions
  before preferring the spell.
- **Compose.** Combine consecutive spells into one (`spell_compose`) when their sequence and
  parameter bindings repeat and no inference decision lies between them. Preserve every
  boundary check.
- **Recover.** On spell failure use inference by default: inspect the trace and reconcile
  effects, then finish safely, repair and reverify the segment, or retire the spell and go back
  to inference. A correct refusal is not a spell defect. Never weaken checks or blindly replay
  effects. Stay within your allowed tools and editable skill scope.

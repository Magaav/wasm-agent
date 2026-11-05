//! The migration engine: ordered never-rewritten steps, a crash journal, refuse-by-default
//! downgrades.
//!
//! # The invariant
//!
//! At every instant the namespace is either at the schema version the meta key names, with exactly
//! the data that version implies, or it carries a journal that says how to get there. A crash is
//! therefore never "a broken namespace": [`Migrator::migrate`] on the next start either finishes the
//! journaled step (replaying a change list of full values) or, if the journal cannot be reconciled,
//! refuses and leaves the pre-migration snapshot as the only way forward.
//!
//! # Write order (the part that makes replay safe)
//!
//! 1. the pre-migration snapshot is taken (read-only),
//! 2. a step computes its whole next batch in memory,
//! 3. the diff is encoded into `__wa/meta/migration/pending`,
//! 4. the journal naming that step is written,
//! 5. the changes are applied, checkpointing `applied` every `checkpoint_every` writes,
//! 6. the schema version moves with one put,
//! 7. the journal and pending list are cleared.
//!
//! A crash before 4 leaves no journal and nothing applied (a stray pending list is dropped). A crash
//! during 5 replays the tail of the change list, which is idempotent by construction. A crash after 6
//! finds a journal whose step already committed and only clears it. A step is never re-run from a
//! half-applied batch, and a step function is only called when the data is at its `from` version.

use crate::batch::{
    decode_changes, diff, encode_changes, validate_changes, Batch, Change, ChangeCounts,
};
use crate::kv::Kv;
use crate::meta::{self, ComponentInfo, Meta};
use crate::snapshot::Snapshot;
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A higher bound than any journal this crate writes; a journal above it is corruption, not work.
const MAX_JOURNAL_JSON: u64 = 4 << 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Up,
    Down,
}

type StepFn = Box<dyn Fn(&mut Batch) -> Result<()> + Send + Sync>;

/// One `vN -> vN+1` migration.
///
/// The step is **never edited once it has shipped**: a later release adds `vN+1 -> vN+2` and leaves
/// this one byte for byte alone. That is what lets a node that has been offline for three releases
/// replay the same path a node that upgraded one release at a time did, and it is why the registry
/// refuses anything but `to == from + 1`.
pub struct Step {
    pub from: u32,
    pub name: String,
    up: StepFn,
    down: Option<StepFn>,
}

impl Step {
    pub fn new(
        from: u32,
        name: impl Into<String>,
        up: impl Fn(&mut Batch) -> Result<()> + Send + Sync + 'static,
    ) -> Self {
        Step {
            from,
            name: name.into(),
            up: Box::new(up),
            down: None,
        }
    }

    /// Register the reverse. Only a step that explicitly provides one can be downgraded through;
    /// "run the up function backwards" is not a thing this crate will guess at.
    pub fn down(
        mut self,
        down: impl Fn(&mut Batch) -> Result<()> + Send + Sync + 'static,
    ) -> Self {
        self.down = Some(Box::new(down));
        self
    }

    pub fn to(&self) -> u32 {
        self.from + 1
    }

    pub fn has_down(&self) -> bool {
        self.down.is_some()
    }

    fn apply_up(&self, batch: &mut Batch) -> Result<()> {
        (self.up)(batch)
    }

    fn apply_down(&self, batch: &mut Batch) -> Result<()> {
        match &self.down {
            Some(down) => down(batch),
            None => Err(Error::NoMigrationPath {
                from: self.to(),
                to: self.from,
                missing: self.from,
                direction: Direction::Down,
            }),
        }
    }
}

/// Every step a component carries, addressable by its `from` version.
pub struct Registry {
    steps: BTreeMap<u32, Step>,
}

impl Registry {
    /// Build a registry. Duplicates and `from == 0` are refused: a version line that forks cannot be
    /// migrated deterministically, and version 0 does not exist ([`meta::open`] starts at 1).
    pub fn new(steps: impl IntoIterator<Item = Step>) -> Result<Self> {
        let mut map: BTreeMap<u32, Step> = BTreeMap::new();
        for step in steps {
            if step.from == 0 {
                return Err(Error::Corrupt(
                    "a migration step cannot start at v0".into(),
                ));
            }
            if step.name.trim().is_empty() {
                return Err(Error::Corrupt("a migration step needs a name".into()));
            }
            if map.insert(step.from, step).is_some() {
                return Err(Error::Corrupt(
                    "two migration steps start at the same version".into(),
                ));
            }
        }
        Ok(Self { steps: map })
    }

    pub fn len(&self) -> usize {
        self.steps.len()
    }

    pub fn is_empty(&self) -> bool {
        self.steps.is_empty()
    }

    /// The highest version any step reaches: what a component that writes natively at the newest
    /// version would start a namespace at.
    pub fn latest(&self) -> Option<u32> {
        self.steps.values().map(Step::to).max()
    }

    pub fn step(&self, from: u32) -> Option<&Step> {
        self.steps.get(&from)
    }

    /// The ordered steps from `from` to `to`, or the reason there are none.
    ///
    /// A downgrade is refused before the path is even looked at unless the caller allowed it; when it
    /// is allowed, one step without a `down` function refuses the whole thing (a half-downgrade would
    /// be a version the component has never produced).
    pub fn plan(&self, from: u32, to: u32, allow_downgrade: bool) -> Result<Vec<PlannedStep<'_>>> {
        if from == to {
            return Ok(Vec::new());
        }
        if from < to {
            let mut plan = Vec::with_capacity((to - from) as usize);
            for version in from..to {
                let step = self.steps.get(&version).ok_or(Error::NoMigrationPath {
                    from,
                    to,
                    missing: version,
                    direction: Direction::Up,
                })?;
                plan.push(PlannedStep {
                    step,
                    direction: Direction::Up,
                });
            }
            Ok(plan)
        } else {
            if !allow_downgrade {
                return Err(Error::DowngradeRefused { from, to });
            }
            let mut plan = Vec::with_capacity((from - to) as usize);
            for version in (to..from).rev() {
                let step = self.steps.get(&version).ok_or(Error::NoMigrationPath {
                    from,
                    to,
                    missing: version,
                    direction: Direction::Down,
                })?;
                if !step.has_down() {
                    return Err(Error::NoMigrationPath {
                        from,
                        to,
                        missing: version,
                        direction: Direction::Down,
                    });
                }
                plan.push(PlannedStep {
                    step,
                    direction: Direction::Down,
                });
            }
            Ok(plan)
        }
    }
}

pub struct PlannedStep<'a> {
    pub step: &'a Step,
    pub direction: Direction,
}

impl PlannedStep<'_> {
    pub fn from(&self) -> u32 {
        match self.direction {
            Direction::Up => self.step.from,
            Direction::Down => self.step.to(),
        }
    }

    pub fn to(&self) -> u32 {
        match self.direction {
            Direction::Up => self.step.to(),
            Direction::Down => self.step.from,
        }
    }

    fn apply(&self, batch: &mut Batch) -> Result<()> {
        match self.direction {
            Direction::Up => self.step.apply_up(batch),
            Direction::Down => self.step.apply_down(batch),
        }
    }
}

/// The record of an unfinished migration, stored under `__wa/meta/migration/journal`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Journal {
    /// Schema version when the run started.
    pub from: u32,
    /// Schema version the run was asked for.
    pub target: u32,
    /// Last version fully committed by this run.
    pub done_upto: u32,
    pub started_at_ms: u64,
    /// How many times a run has written this journal. A number that keeps growing is an operator
    /// signal (`wa state ...` can show it) even though every resume is safe.
    pub attempts: u32,
    pub component: String,
    pub pending_step: Option<PendingStep>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingStep {
    pub from: u32,
    pub to: u32,
    pub name: String,
    pub direction: Direction,
    /// Changes already applied (index into the pending list). The engine replays from here.
    pub applied: usize,
}

/// Read the journal without touching it: what a `wa state status` would show.
pub fn journal(kv: &mut dyn Kv) -> Result<Option<Journal>> {
    read_journal(kv)
}

fn read_journal(kv: &mut dyn Kv) -> Result<Option<Journal>> {
    let Some(raw) = kv.get(meta::key::JOURNAL)? else {
        return Ok(None);
    };
    if raw.len() as u64 > MAX_JOURNAL_JSON {
        return Err(Error::Limit {
            what: "migration journal",
            limit: MAX_JOURNAL_JSON,
            found: raw.len() as u64,
        });
    }
    serde_json::from_slice(&raw)
        .map(Some)
        .map_err(|error| Error::Corrupt(format!("migration journal does not parse: {error}")))
}

fn write_journal(kv: &mut dyn Kv, journal: &Journal) -> Result<()> {
    let bytes = serde_json::to_vec(journal)
        .map_err(|error| Error::Kv(format!("journal encode: {error}")))?;
    kv.put(meta::key::JOURNAL, &bytes)
}

fn clear_journal(kv: &mut dyn Kv) -> Result<()> {
    kv.del(meta::key::JOURNAL)?;
    kv.del(meta::key::PENDING)?;
    Ok(())
}

/// Tuning for one migration. The defaults are what the host should use; every field exists because
/// a bound below is a policy decision (memory, write amplification), not an implementation detail.
#[derive(Clone, Debug)]
pub struct MigrateOptions {
    /// Run registered `down` steps. Off by default: a downgrade is an operator action.
    pub allow_downgrade: bool,
    /// Journal `applied` after this many writes. `0` checkpoints after every write (slowest, least
    /// replay on resume); the default trades at most 31 idempotent re-applies for a fraction of the
    /// writes.
    pub checkpoint_every: usize,
    /// Largest namespace (keys + values) a migration will load into memory.
    pub max_batch_bytes: u64,
    /// Largest encoded change list one step may journal. Defaults to `max_batch_bytes`: a step is
    /// allowed to rewrite everything it was given, and the write must fail *before* the journal
    /// half-describes it.
    pub max_journal_bytes: u64,
}

impl Default for MigrateOptions {
    fn default() -> Self {
        Self {
            allow_downgrade: false,
            checkpoint_every: 32,
            max_batch_bytes: 256 << 20,
            max_journal_bytes: 256 << 20,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StepReport {
    pub from: u32,
    pub to: u32,
    pub name: String,
    pub counts: ChangeCounts,
    /// True when this step was finished from the journal instead of being computed now.
    pub resumed: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MigrationReport {
    pub from: u32,
    pub target: u32,
    pub final_version: u32,
    pub steps: Vec<StepReport>,
    pub totals: ChangeCounts,
    /// An interrupted step was found and finished before planning the rest.
    pub resumed: bool,
    pub dry_run: bool,
    /// The snapshot taken before the first write. Kept even when a sink persisted it, because a
    /// caller that wants to compare before/after needs the bytes; drop the report (or take this
    /// field) instead of holding it for a large namespace.
    pub snapshot: Option<Snapshot>,
}

/// Where the mandatory pre-migration snapshot goes. Implement it to write a file, upload a backup,
/// or keep the bytes in memory. Called exactly once, before any write, and an error here aborts the
/// migration with the namespace untouched.
pub trait SnapshotSink {
    fn write(&mut self, meta: &Meta, snapshot: &Snapshot) -> Result<()>;
}

/// A sink for callers that only need the copy in [`MigrationReport::snapshot`].
impl SnapshotSink for () {
    fn write(&mut self, _meta: &Meta, _snapshot: &Snapshot) -> Result<()> {
        Ok(())
    }
}

pub struct Migrator<'a> {
    kv: &'a mut dyn Kv,
    registry: &'a Registry,
    info: &'a ComponentInfo,
    options: MigrateOptions,
}

impl<'a> Migrator<'a> {
    pub fn new(kv: &'a mut dyn Kv, registry: &'a Registry, info: &'a ComponentInfo) -> Self {
        Self {
            kv,
            registry,
            info,
            options: MigrateOptions::default(),
        }
    }

    pub fn options(mut self, options: MigrateOptions) -> Self {
        self.options = options;
        self
    }

    /// Report what the migration would change without writing anything - not even a timestamp.
    /// A journal left by an earlier crash is included: its remaining changes are counted against the
    /// current data instead of re-running the step from a half-applied batch.
    pub fn dry_run(&mut self, target: u32) -> Result<MigrationReport> {
        let meta = self.open_meta()?;
        let mut report = MigrationReport {
            from: meta.schema_version,
            target,
            final_version: meta.schema_version,
            dry_run: true,
            ..Default::default()
        };
        let mut batch = Batch::load(self.kv, self.options.max_batch_bytes)?;
        let mut version = meta.schema_version;

        if let Some(journal) = read_journal(self.kv)? {
            if let Some(pending) = &journal.pending_step {
                report.resumed = true;
                if version == pending.from {
                    let changes = match self.kv.get(meta::key::PENDING)? {
                        Some(raw) => decode_changes(&raw)?,
                        None => {
                            return Err(Error::JournalInconsistent(
                                "pending changes are missing".into(),
                            ))
                        }
                    };
                    let applied = pending.applied.min(changes.len());
                    let counts = apply_to_batch(&mut batch, &changes[applied..])?;
                    report.steps.push(StepReport {
                        from: pending.from,
                        to: pending.to,
                        name: pending.name.clone(),
                        counts,
                        resumed: true,
                    });
                    report.totals.add(counts);
                    version = pending.to;
                }
            }
        }

        // A downgrade is refused here exactly as it would be by the real run, before any write.
        for planned in self
            .registry
            .plan(version, target, self.options.allow_downgrade)?
        {
            let mut next = batch.clone();
            planned.apply(&mut next)?;
            let (counts, _) = diff(&batch, &next);
            report.steps.push(StepReport {
                from: planned.from(),
                to: planned.to(),
                name: planned.step.name.clone(),
                counts,
                resumed: false,
            });
            report.totals.add(counts);
            version = planned.to();
            batch = next;
        }
        report.final_version = version;
        Ok(report)
    }

    /// Migrate to `target`. The snapshot is taken and handed to `sink` before the first write; pass
    /// `&mut ()` when [`MigrationReport::snapshot`] is enough.
    pub fn migrate(
        &mut self,
        target: u32,
        now_ms: u64,
        sink: &mut dyn SnapshotSink,
    ) -> Result<MigrationReport> {
        let mut meta = self.open_meta()?;
        if target == 0 {
            return Err(Error::Corrupt("schema versions start at 1".into()));
        }
        // Refuse the plan before the snapshot (and thus before any write): a missing step or a
        // refused downgrade must not leave a snapshot file behind as if work had started.
        self.registry
            .plan(meta.schema_version, target, self.options.allow_downgrade)?;

        let snapshot = Snapshot::take(self.kv, &meta, now_ms, self.options.max_batch_bytes)?;
        sink.write(&meta, &snapshot)?;
        let mut batch = snapshot.batch()?;

        let mut report = MigrationReport {
            from: meta.schema_version,
            target,
            final_version: meta.schema_version,
            snapshot: Some(snapshot),
            ..Default::default()
        };
        let mut version = meta.schema_version;

        // 1. Finish a step a previous run left half-applied.
        if let Some(journal) = read_journal(self.kv)? {
            if let Some(pending) = journal.pending_step.clone() {
                version = self.resume(&journal, &pending, now_ms, &mut batch, &mut report)?;
                report.resumed = true;
            } else {
                // The journal outlived its step: the crash was between commit and clear. Nothing is
                // in flight, so drop it rather than resuming work that does not exist.
                clear_journal(self.kv)?;
            }
        }
        // A pending list without a journal means the crash was between the two journal writes -
        // before anything was applied. Dropping it lets the step be recomputed.
        if self.kv.get(meta::key::PENDING)?.is_some() && read_journal(self.kv)?.is_none() {
            self.kv.del(meta::key::PENDING)?;
        }

        // 2. Walk the rest of the path from wherever the resume left the data.
        for planned in self
            .registry
            .plan(version, target, self.options.allow_downgrade)?
        {
            let mut next = batch.clone();
            planned.apply(&mut next)?;
            let (counts, changes) = diff(&batch, &next);
            let next_version = planned.to();

            if !changes.is_empty() {
                validate_changes(&changes)?;
                let encoded = encode_changes(&changes);
                if encoded.len() as u64 > self.options.max_journal_bytes {
                    return Err(Error::Limit {
                        what: "step change list",
                        limit: self.options.max_journal_bytes,
                        found: encoded.len() as u64,
                    });
                }
                let mut journal = Journal {
                    from: version,
                    target,
                    done_upto: version,
                    started_at_ms: now_ms,
                    attempts: 1,
                    component: self.info.id.clone(),
                    pending_step: Some(PendingStep {
                        from: version,
                        to: next_version,
                        name: planned.step.name.clone(),
                        direction: planned.direction,
                        applied: 0,
                    }),
                };
                // Pending first, journal second: a journal always has the list it names.
                self.kv.put(meta::key::PENDING, &encoded)?;
                write_journal(self.kv, &journal)?;
                self.apply_changes(&mut journal, &changes, 0)?;
            }

            // Commit, then clear. The other order is a data-corrupting bug the crash test found: a
            // crash between "clear the journal" and "move the version" leaves data at the next
            // version while the meta still names the previous one, so the next run would migrate it
            // a second time (a value prefix becomes `v3:v3:...`). With this order, a crash in the
            // gap leaves a journal whose step already committed, which resume only clears.
            meta.schema_version = next_version;
            meta.set_schema_version(self.kv, next_version, now_ms)?;
            if !changes.is_empty() {
                clear_journal(self.kv)?;
            }
            batch = next;
            version = next_version;
            report.steps.push(StepReport {
                from: planned.from(),
                to: next_version,
                name: planned.step.name.clone(),
                counts,
                resumed: false,
            });
            report.totals.add(counts);
        }

        // 3. Record the build that moved the data. A run with no steps is not a migration, and must
        // not claim to be the last one. The version is synced first: when the only work this run did
        // was finish a journaled step, the plan loop above wrote nothing, and `meta` still holds the
        // version read before the resume - writing it here would undo the commit.
        meta.schema_version = version;
        if !report.steps.is_empty() {
            meta.last_migrated_by = self.info.sha256.clone();
            meta.last_migrated_at_ms = now_ms;
            meta.component_version = self.info.version.clone();
            meta.write(self.kv, now_ms)?;
        }
        report.final_version = version;
        Ok(report)
    }

    fn open_meta(&mut self) -> Result<Meta> {
        self.info.validate()?;
        let meta = Meta::read(self.kv)?.ok_or(Error::Uninitialised { keys: 0 })?;
        if meta.component != self.info.id {
            return Err(Error::OwnerMismatch {
                expected: self.info.id.clone(),
                found: meta.component,
            });
        }
        Ok(meta)
    }

    /// Finish the journaled step. Returns the schema version afterwards.
    fn resume(
        &mut self,
        journal: &Journal,
        pending: &PendingStep,
        now_ms: u64,
        batch: &mut Batch,
        report: &mut MigrationReport,
    ) -> Result<u32> {
        // The step function is not called here: the journaled change list was produced by it, and
        // re-running a possibly non-idempotent step from a half-applied batch is exactly the bug the
        // journal exists to prevent. Without the step in the registry we cannot vouch for either.
        let step = match self.registry.step(pending.from) {
            Some(step) if step.to() == pending.to => step,
            _ => {
                return Err(Error::JournalInconsistent(format!(
                    "the v{} -> v{} step is no longer registered; restore the pre-migration snapshot",
                    pending.from, pending.to
                )))
            }
        };
        let changes = match self.kv.get(meta::key::PENDING)? {
            Some(raw) => decode_changes(&raw)?,
            None => {
                return Err(Error::JournalInconsistent(
                    "pending changes are missing; restore the pre-migration snapshot".into(),
                ))
            }
        };
        let meta = Meta::read(self.kv)?.ok_or(Error::Uninitialised { keys: 0 })?;
        if meta.schema_version == pending.to {
            // Committed before the crash; only the clear was lost.
            clear_journal(self.kv)?;
            return Ok(meta.schema_version);
        }
        if meta.schema_version != pending.from {
            return Err(Error::JournalInconsistent(format!(
                "state is at v{} but the journal expects v{} or v{}; restore the pre-migration snapshot",
                meta.schema_version, pending.from, pending.to
            )));
        }
        let applied = pending.applied.min(changes.len());
        let counts = apply_to_batch(batch, &changes[applied..])?;

        let mut replay = journal.clone();
        if let Some(entry) = replay.pending_step.as_mut() {
            entry.applied = applied;
        }
        replay.attempts = replay.attempts.saturating_add(1);
        write_journal(self.kv, &replay)?;
        self.apply_changes(&mut replay, &changes, applied)?;

        let mut meta = meta;
        meta.schema_version = pending.to;
        meta.set_schema_version(self.kv, pending.to, now_ms)?;
        clear_journal(self.kv)?;
        report.steps.push(StepReport {
            from: pending.from,
            to: pending.to,
            name: step.name.clone(),
            counts,
            resumed: true,
        });
        report.totals.add(counts);
        Ok(pending.to)
    }

    /// Apply from `changes[from..]`, checkpointing the index so a crash resumes there.
    fn apply_changes(&mut self, journal: &mut Journal, changes: &[Change], from: usize) -> Result<()> {
        for index in from..changes.len() {
            match &changes[index] {
                Change::Put { key, value } => self.kv.put(key, value)?,
                Change::Del { key } => self.kv.del(key)?,
            }
            let done = index + 1;
            let checkpoint = self.options.checkpoint_every == 0
                || done % self.options.checkpoint_every == 0
                || done == changes.len();
            if checkpoint && done < changes.len() {
                if let Some(entry) = journal.pending_step.as_mut() {
                    entry.applied = done;
                }
                write_journal(self.kv, journal)?;
            }
        }
        Ok(())
    }
}

/// Apply a change list to a batch, counting what it actually changes. Used when finishing a
/// journaled step, where the "before" batch is only known through the changes still left.
fn apply_to_batch(batch: &mut Batch, changes: &[Change]) -> Result<ChangeCounts> {
    let mut counts = ChangeCounts::default();
    for change in changes {
        match change {
            Change::Put { key, value } => match batch.get(key) {
                None => {
                    counts.added += 1;
                    batch.insert(key, value.clone())?;
                }
                Some(old) if old != value.as_slice() => {
                    counts.changed += 1;
                    batch.insert(key, value.clone())?;
                }
                Some(_) => counts.unchanged += 1,
            },
            Change::Del { key } => {
                if batch.remove(key).is_some() {
                    counts.removed += 1;
                }
            }
        }
    }
    Ok(counts)
}

//! Record and replay hooks, on `wa-bounded`'s bounded ring (`docs/REPLAY.md`).
//!
//! One record per answered host call: who answered (`wa:kernel/kv`, `get`), what was asked, what was
//! answered. Recording is the ring the node uses - bytes and age bounded, `wa-bounded`'s file format -
//! so a failure recorded under a test is the same artifact `wa replay` reads on a node.
//!
//! Replay feeds the answers back in order. Order, interface and function must all match: a replay
//! that has drifted is [`Journal::mismatch`] and the guest receives `failed(replay_mismatch:…)`,
//! because answering the wrong question with the right bytes is worse than failing.
//!
//! What is a step: everything that leaves the kernel's memory. kv, log, lifecycle and credentials are
//! one step per call. `http.send` is one step holding the whole response (status, headers, body) -
//! the body's chunks are the host's own chopping, not something the peer decided, so re-chopping is
//! not a difference. `websocket.connect` holds the connection's frames and its echo flag, and
//! `speech.recognize` holds the recognition, for the same reason: the framing of a stream belongs to
//! the fake kernel, the content belongs to the peer.

use crate::{Answer, Call};
use std::collections::VecDeque;
use std::path::Path;
use std::time::SystemTime;
use wa_bounded::{caps, BlobStore, NewRecord, Record, RecordRing, RingConfig, SaveOptions, Trigger};

/// 64 MiB of records: a dev/test ring, big enough for a whole fixture run and still bounded.
const RING_BYTES: u64 = 64 * 1024 * 1024;
/// Anything under this stays inline in the ring: a fake kernel has no blob store, and a spilled
/// payload would be recorded as a digest the replay cannot answer with.
const INLINE_THRESHOLD: u64 = 8 * 1024 * 1024;

enum Mode {
    Off,
    Record,
    Replay(VecDeque<Record>),
}

/// The kernel's record/replay state.
pub struct Journal {
    mode: Mode,
    ring: RecordRing,
    /// The first place a replay stopped matching the component, if it did.
    mismatch: Option<String>,
    /// How many steps a replay has left (for the "the component made more calls than recorded"
    /// case, which is a mismatch with its own name).
    remaining: usize,
}

impl Default for Journal {
    fn default() -> Self {
        Journal::off()
    }
}

impl Journal {
    pub fn off() -> Journal {
        Journal { mode: Mode::Off, ring: RecordRing::new(RingConfig::default()), mismatch: None, remaining: 0 }
    }

    /// Record every answered call into the ring.
    pub fn recording() -> Journal {
        Journal {
            mode: Mode::Record,
            ring: RecordRing::new(RingConfig {
                max_bytes: RING_BYTES,
                max_age: caps::RING_MAX_AGE,
                blob_threshold: INLINE_THRESHOLD,
                keep_args: true,
            }),
            mismatch: None,
            remaining: 0,
        }
    }

    /// Answer from a saved replay instead of the scripts.
    pub fn replaying(path: &Path) -> Result<Journal, String> {
        let replay = wa_bounded::Replay::load(path).map_err(|error| format!("replay_unreadable:{}:{error}", path.display()))?;
        replay.verify().map_err(|error| format!("replay_corrupt:{error}"))?;
        let remaining = replay.records.len();
        Ok(Journal { mode: Mode::Replay(replay.records.into()), ring: RecordRing::new(RingConfig::default()), mismatch: None, remaining })
    }

    pub fn is_recording(&self) -> bool {
        matches!(self.mode, Mode::Record)
    }
    pub fn is_replaying(&self) -> bool {
        matches!(self.mode, Mode::Replay(_))
    }
    /// How many records the ring holds (after a run: how many steps a saved replay would contain).
    pub fn records(&self) -> u64 {
        self.ring.len() as u64
    }
    /// How many steps a replay has not consumed: a non-zero count means the component asked for less
    /// than was recorded, which is reported by the caller as a warning, not a failure.
    pub fn remaining(&self) -> usize {
        self.remaining
    }
    pub fn mismatch(&self) -> Option<&str> {
        self.mismatch.as_deref()
    }
    pub fn ring(&self) -> &RecordRing {
        &self.ring
    }

    /// The answer to feed back, when this journal is replaying.
    pub fn ask(&mut self, interface: &str, function: &str, args: &serde_json::Value) -> Option<Answer> {
        let Mode::Replay(records) = &mut self.mode else { return None };
        let Some(record) = records.pop_front() else {
            let mismatch = format!("replay_exhausted:{interface}.{function}");
            self.mismatch.get_or_insert_with(|| mismatch.clone());
            return Some(Answer::Err(mismatch));
        };
        self.remaining = records.len();
        if record.interface != interface || record.function != function {
            let mismatch = format!(
                "replay_mismatch:seq={}:recorded={}.{}:asked={interface}.{function}",
                record.seq, record.interface, record.function
            );
            self.mismatch.get_or_insert_with(|| mismatch.clone());
            return Some(Answer::Err(mismatch));
        }
        if let Some(kept) = record.args.inline_bytes() {
            let recorded = String::from_utf8_lossy(kept);
            let asked = serde_json::to_string(args).unwrap_or_default();
            if recorded != asked {
                // Arguments that differ are a different call: the same function name is not enough
                // for a replay to be evidence (a kv.get of another key answers a question nobody
                // asked). Recorded with a JSON object, so a formatting difference is the only
                // tolerated kind.
                let mismatch = format!("replay_arguments_differ:{interface}.{function}:recorded={recorded}:asked={asked}");
                self.mismatch.get_or_insert_with(|| mismatch.clone());
                return Some(Answer::Err(mismatch));
            }
        }
        match record.result.inline_bytes() {
            Some(bytes) => Some(Answer::decode(&String::from_utf8_lossy(bytes))),
            None => Some(Answer::Err(format!("replay_step_without_answer:{interface}.{function}"))),
        }
    }

    /// Write the answer down (recording only) and hand it to the call log.
    pub fn note(&mut self, call: &Call, asked: &serde_json::Value, answer: &Answer) {
        if !self.is_recording() {
            return;
        }
        let args = serde_json::to_vec(asked).unwrap_or_default();
        let result = answer.encode();
        let pushed = self.ring.push(NewRecord {
            interface: &call.interface,
            function: &call.function,
            args: &args,
            result: Some(result.as_bytes()),
            duration: std::time::Duration::from_micros(0),
            ts: SystemTime::now(),
        });
        if let Err(error) = pushed {
            // A ring that refuses a record must say so; it is reported through the same field a
            // replay mismatch uses, because both mean "the evidence is incomplete".
            self.mismatch.get_or_insert_with(|| format!("record_refused:{error}"));
        }
    }

    /// Write the ring into `dir` as one `.wrz` file, and return its path.
    pub fn save(&self, dir: &Path, label: &str) -> Result<std::path::PathBuf, String> {
        if self.ring.is_empty() {
            return Err("nothing_recorded".into());
        }
        let bounded = wa_bounded::BoundedDir::open(dir, caps::REPLAY_QUOTA_BYTES).map_err(|error| format!("replay_dir:{error}"))?;
        let options = SaveOptions { trigger: Trigger::Manual, label: label.to_string(), pin: false };
        let saved = wa_bounded::save(&self.ring, &bounded, &options, SystemTime::now()).map_err(|error| format!("replay_save:{error}"))?;
        Ok(dir.join(saved.name))
    }
}

impl Answer {
    /// The bytes a record holds: `ok:<json>` or `err:<reason>`, one line of evidence either way.
    pub fn encode(&self) -> String {
        match self {
            Answer::Ok(value) => format!("ok:{value}"),
            Answer::Err(reason) => format!("err:{reason}"),
        }
    }

    /// Read a record back. A record that is neither form is an error, not an empty answer.
    pub fn decode(text: &str) -> Answer {
        match text.strip_prefix("ok:") {
            Some(json) => match serde_json::from_str::<serde_json::Value>(json) {
                Ok(value) => Answer::Ok(value),
                Err(error) => Answer::Err(format!("replay_answer_unreadable:{error}")),
            },
            None => match text.strip_prefix("err:") {
                Some(reason) => Answer::Err(reason.to_string()),
                None => Answer::Err("replay_answer_unreadable:no_prefix".into()),
            },
        }
    }
}

/// An unused blob store, so a caller that wants the ring's digest path has one to hand: the fake
/// kernel never spills (its threshold is the whole ring), and the node's store is its own.
pub fn no_blobs() -> Option<BlobStore> {
    None
}

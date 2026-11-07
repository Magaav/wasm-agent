//! A fixture: the memory seam, crashed between its write and its journal entry.
//!
//! `remember` opens the kernel's unit of work, writes the fact and its search row, and then:
//!
//! - when the content starts with `wedge`: spins forever, so the caller's epoch deadline kills the
//!   guest mid-call with the unit still open — the shape a crash between "the rows are written" and
//!   "the journal entry exists" has. SQLite rolls the unit back when the session is dropped.
//! - otherwise: asks the kernel to commit a journal entry that cannot be written (the payload is not
//!   a JSON object), which the kernel must refuse *and* roll the fact back with.
//!
//! Either way the store must not end up with a fact and no entry, or an entry and no fact. The test
//! that uses it is `a_guest_killed_between_the_write_and_the_journal_leaves_neither` in
//! `rust/wa-kernel-runtime/src/memory_host/tests.rs`.
//!
//! Never install it on a node under the name `memory`.
wit_bindgen::generate!({ path: "../../../wit/memory", world: "memory-component", generate_all });

use crate::exports::wa::memory::memory::{Guest, RetentionPlan};
use crate::wa::kernel::sql;
use crate::wa::memory::types::{Error as MError, Forgotten, Memory, MessageHit, Remembered, Session};

struct Crash;

const ID: &str = "crash-fixture";
const CONTENT: &str = "the fact the fixture writes before it dies";

fn fault(error: sql::Error) -> MError {
    match error {
        sql::Error::Refused(why) => MError::Refused(why),
        sql::Error::Failed(why) => MError::Failed(why),
        sql::Error::Again => MError::Failed("again".into()),
        sql::Error::Closed => MError::Failed("closed".into()),
    }
}

fn spin() -> ! {
    loop {
        std::hint::spin_loop();
    }
}

impl Guest for Crash {
    fn remember(content: String, _scope: Option<String>, _tags: Vec<String>, _id: Option<String>) -> Result<Remembered, MError> {
        // One unit of work, exactly as the real component opens it.
        sql::begin_unit().map_err(fault)?;
        sql::exec(
            "INSERT INTO memories(id,scope,content,tags,source,created_at,updated_at,content_sha256) \
             VALUES(?,'global',?,'[]','user',1.0,1.0,'fixture')",
            &[sql::Value::Text(ID.into()), sql::Value::Text(CONTENT.into())],
        )
        .map_err(fault)?;
        sql::exec(
            "INSERT INTO memories_fts(content,tags,memory_id) VALUES(?,'',?)",
            &[sql::Value::Text(CONTENT.into()), sql::Value::Text(ID.into())],
        )
        .map_err(fault)?;
        if content.starts_with("wedge") {
            // Killed here by the caller's deadline: `commit_unit` is never reached.
            spin();
        }
        // A payload the kernel cannot hand a peer. It must refuse *and* roll the fact back.
        let entry = sql::JournalEntry { entity_id: ID.into(), op: "upsert".into(), payload: "{".into() };
        sql::commit_unit(Some(&entry)).map_err(fault)?;
        Ok(Remembered {
            id: ID.into(),
            scope: "global".into(),
            content: CONTENT.into(),
            tags: Vec::new(),
            source: "user".into(),
            created_at: 1.0,
            updated_at: 1.0,
            content_sha256: "fixture".into(),
            written: true,
        })
    }

    fn recall(_text: String, _limit: u32, _scope: Option<String>, _exclusive: bool) -> Result<Vec<Memory>, MError> {
        Ok(Vec::new())
    }
    fn forget(_id: String) -> Result<Forgotten, MError> {
        Err(MError::Invalid("fixture_forget".into()))
    }
    fn list(_scope: Option<String>, _limit: u32) -> Result<Vec<Memory>, MError> {
        Ok(Vec::new())
    }
    fn search_messages(_text: String, _user_id: Option<String>, _limit: u32) -> Result<Vec<MessageHit>, MError> {
        Ok(Vec::new())
    }
    fn sessions(_user_id: Option<String>, _limit: u32, _states: bool) -> Result<Vec<Session>, MError> {
        Ok(Vec::new())
    }
    fn retention(_older_than_seconds: f64) -> Result<RetentionPlan, MError> {
        Ok(RetentionPlan { refused: None, eligible: 0 })
    }
}

export!(Crash);

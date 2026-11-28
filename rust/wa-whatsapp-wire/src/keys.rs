//! The index's key layout, in one place.
//!
//! The layout was written down in the component (`rust/components/wa-whatsapp/src/index.rs`) because
//! the component was its only writer. Retention and the monthly archive made it a two-writer fact: the
//! node cuts a month out of the index and puts it back, and a node that *recomputed* the keys from its
//! own copy of the format would drift from the component's the first time either changed - a cut that
//! missed `ix/w/…` leaves a search hit with no record behind it, and a restore that missed it writes a
//! month nobody can find. So the layout lives in the seam both ends already link, and the component
//! calls these functions instead of holding its own copy.
//!
//! ```text
//! ix/m/<chat>/<inv(ts)>/<id>            the record, JSON
//! ix/id/<chat>/<id>                     inv(ts)
//! ix/s/<sender>/<inv(ts)>/<id>/<chat>   empty
//! ix/k/<kind>/<inv(ts)>/<id>/<chat>     empty
//! ix/w/<token>/<inv(ts)>/<id>/<chat>    empty
//! ix/x/<chat>/<id>/<reactor>/<emoji>    reaction, JSON
//! ix/all/<ts>/<chat>/<id>               `history` | empty   (age order: retention walks it)
//! ix/ocr/<chat>/<id>                    the OCR lane's mark
//! ix/arc/<YYYY-MM>                      the archive mark: a month that is restored here
//! ```
//!
//! `inv(ts)` is `u64::MAX - ts` as fixed-width hex, so an ascending scan yields the newest first;
//! `ix/all` is the opposite (plain `ts`) because retention and the archive walk from the oldest.

/// Every key the index owns starts here (`kv.write` policy rules it as `ix/*`).
pub const PREFIX: &str = "ix/";

/// The newest-first form of a timestamp: `u64::MAX - ts`, fixed width, so a byte order is a time order.
pub fn inv(ts: i64) -> String {
    format!("{:016x}", u64::MAX - (ts.max(0) as u64))
}

/// The oldest-first form of a timestamp: plain, fixed width.
pub fn age(ts: i64) -> String {
    format!("{:016x}", ts.max(0) as u64)
}

/// The timestamp an `ix/all` key carries, or `None` when the key is not one.
pub fn from_age(text: &str) -> Option<i64> {
    u64::from_str_radix(text, 16).ok().and_then(|value| i64::try_from(value).ok())
}

pub fn message(chat: &str, ts: i64, id: &str) -> String {
    format!("{PREFIX}m/{chat}/{}/{id}", inv(ts))
}

pub fn message_prefix(chat: &str) -> String {
    format!("{PREFIX}m/{chat}/")
}

pub fn id(chat: &str, id: &str) -> String {
    format!("{PREFIX}id/{chat}/{id}")
}

/// The age key (`ix/all/…`): what retention walks and what the archive reads the month out of.
pub fn age_key(ts: i64, chat: &str, id: &str) -> String {
    format!("{PREFIX}all/{}/{chat}/{id}", age(ts))
}

pub fn sender(sender: &str, ts: i64, id: &str, chat: &str) -> String {
    format!("{PREFIX}s/{sender}/{}/{id}/{chat}", inv(ts))
}

pub fn kind(kind: &str, ts: i64, id: &str, chat: &str) -> String {
    format!("{PREFIX}k/{kind}/{}/{id}/{chat}", inv(ts))
}

pub fn token(token: &str, ts: i64, id: &str, chat: &str) -> String {
    format!("{PREFIX}w/{token}/{}/{id}/{chat}", inv(ts))
}

pub fn reaction(chat: &str, target: &str, reactor: &str, emoji: &str) -> String {
    format!("{PREFIX}x/{chat}/{target}/{reactor}/{emoji}")
}

pub fn reaction_prefix(chat: &str, target: &str) -> String {
    format!("{PREFIX}x/{chat}/{target}/")
}

pub fn ocr_seen(chat: &str, id: &str) -> String {
    format!("{PREFIX}ocr/{chat}/{id}")
}

pub fn chat_card(chat: &str) -> String {
    format!("{PREFIX}ct/{chat}")
}

/// The mark that says a month is loaded here from its archive (`ix/arc/<YYYY-MM>`).
///
/// It is the one key an archive writes that is not part of a record, and it is what a read looks at to
/// answer "this came from a restored month" without trusting the record's own flag alone.
pub fn archive_mark(month: &str) -> String {
    format!("{PREFIX}arc/{month}")
}

/// The prefix every archive mark lives under (one scan lists the months restored here).
pub fn archive_prefix() -> String {
    format!("{PREFIX}arc/")
}

/// The facts one record carries that decide the keys pointing at it.
///
/// The token list is passed in because the *tokens* are the record's searchable text, folded and
/// bounded ([`crate::tokens`]); everything else is a field the record already states.
#[derive(Clone, Debug, Default)]
pub struct RecordFacts {
    pub chat: String,
    pub id: String,
    pub sender: String,
    pub ts: i64,
    pub kind: String,
    /// `history` when the record was backfilled (the `ix/all` value), empty for a live one.
    pub source: String,
    pub tokens: Vec<String>,
}

impl RecordFacts {
    /// Every key that points at this record, in the order the index writes them.
    ///
    /// This is the whole answer to "what does cutting a record out of the index mean": [`remove`] in the
    /// component deletes exactly this list, and the archive carries exactly this list, so a restored
    /// month is the month that was cut and not an approximation of it.
    ///
    /// [`remove`]: https://docs.rs
    pub fn keys(&self) -> Vec<String> {
        let mut keys = Vec::with_capacity(5 + self.tokens.len());
        keys.push(message(&self.chat, self.ts, &self.id));
        keys.push(id(&self.chat, &self.id));
        keys.push(age_key(self.ts, &self.chat, &self.id));
        keys.push(sender(&self.sender, self.ts, &self.id, &self.chat));
        keys.push(kind(&self.kind, self.ts, &self.id, &self.chat));
        for word in &self.tokens {
            keys.push(token(word, self.ts, &self.id, &self.chat));
        }
        keys
    }

    /// The value each [key](Self::keys) holds, in the same order: the record itself under its message
    /// key, the two derived words, and empty for the pointers.
    pub fn values(&self, record_json: &[u8]) -> Vec<Vec<u8>> {
        let mut values = Vec::with_capacity(5 + self.tokens.len());
        values.push(record_json.to_vec());
        values.push(inv(self.ts).into_bytes());
        values.push(self.source.clone().into_bytes());
        for _ in 0..(2 + self.tokens.len()) {
            values.push(Vec::new());
        }
        values
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_two_orders_are_opposites_and_round_trip() {
        // A scan of `ix/m` yields the newest first and a scan of `ix/all` the oldest first, and both
        // encode the same timestamp without losing it.
        let older = 1_700_000_000_000i64;
        let newer = older + 1;
        assert!(inv(older) > inv(newer), "the newest sorts first in the thread order");
        assert!(age(older) < age(newer), "the oldest sorts first in the age order");
        assert_eq!(from_age(&age(older)), Some(older));
        assert_eq!(from_age(&age(newer)), Some(newer));
        assert_eq!(from_age("not-hex"), None);
        // Fixed width is what makes a byte order a time order, at every magnitude.
        assert_eq!(inv(0).len(), 16);
        assert_eq!(age(i64::MAX).len(), 16);
    }

    #[test]
    fn a_records_keys_are_the_record_and_the_pointers_at_it() {
        let facts = RecordFacts {
            chat: "5511999999999@s.whatsapp.net".into(),
            id: "3EB0ABCDEF".into(),
            sender: "5511888888888@s.whatsapp.net".into(),
            ts: 1_700_000_000_000,
            kind: "text".into(),
            source: "history".into(),
            tokens: vec!["acao".into(), "relatorio".into()],
        };
        let keys = facts.keys();
        assert_eq!(keys.len(), 7, "record, id, age, sender, kind and two tokens");
        assert_eq!(keys[0], format!("ix/m/5511999999999@s.whatsapp.net/{}/3EB0ABCDEF", inv(facts.ts)));
        assert_eq!(keys[1], "ix/id/5511999999999@s.whatsapp.net/3EB0ABCDEF");
        assert_eq!(keys[2], format!("ix/all/{}/5511999999999@s.whatsapp.net/3EB0ABCDEF", age(facts.ts)));
        assert!(keys[3].starts_with("ix/s/5511888888888@s.whatsapp.net/"));
        assert!(keys[4].starts_with("ix/k/text/"));
        assert!(keys[5].starts_with("ix/w/acao/"));
        assert!(keys[6].starts_with("ix/w/relatorio/"));
        // The values line up with the keys one for one, and the record is the first of them.
        let values = facts.values(b"{\"id\":\"3EB0ABCDEF\"}");
        assert_eq!(values.len(), keys.len());
        assert_eq!(values[0], b"{\"id\":\"3EB0ABCDEF\"}");
        assert_eq!(values[1], inv(facts.ts).as_bytes());
        assert_eq!(values[2], b"history");
        assert!(values[3].is_empty() && values[6].is_empty());
    }

    #[test]
    fn the_archive_mark_is_one_key_per_month_under_its_own_prefix() {
        assert_eq!(archive_mark("2026-04"), "ix/arc/2026-04");
        let prefix = archive_prefix();
        assert!(archive_mark("2026-04").starts_with(&prefix));
        // It cannot be mistaken for a record key or for a token key: a restore writes nothing under a
        // prefix the record walk reads.
        assert!(!archive_mark("2026-04").starts_with("ix/m/"));
        assert!(!archive_mark("2026-04").starts_with("ix/w/"));
    }
}

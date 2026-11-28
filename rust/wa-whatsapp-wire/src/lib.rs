//! The WhatsApp index's layout, as data: the keys a message is stored under, the text rules a search folds
//! and tokenises by, and the month a conversation is addressed by.
//!
//! Read `Cargo.toml` for why this is a crate of its own. The short version: both ends of the index must
//! agree on these three things, one end is the host's archive (which may not link the query contract) and
//! the other is the `wa-whatsapp` component, and none of it is a decision - it is a shape.
pub mod keys;
pub mod month;
pub mod text;

pub use text::{fold, name_key, tokenize, tokens, Searchable, MAX_TOKENS};

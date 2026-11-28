//! The seam mirrors the contract's op names and its op -> effect table, because a caller has to name an op
//! locally. This is the test that keeps the mirror honest: it compares the host's table with
//! `rust/wa-whatsapp-index`'s own, op by op.
//!
//! WHY IT EXISTS. On 28/11 the seam was written with `download` as the only non-read op, and `backfill` -
//! which asks the phone for history and is a NETWORK op - was called read-only. The host sent the call to
//! the index door and `scripts/test-whatsapp-index.lua` failed with `whatsapp_backfill_use_its_own_door`:
//! the row caught it, but only after a build. This test catches it before one.
use super::*;
use wa_whatsapp_index as contract;

#[test]
fn every_op_the_contract_names_is_an_op_here() {
    let theirs: Vec<&str> = contract::Op::ALL.iter().map(|op| op.as_str()).collect();
    let ours: Vec<&str> = Op::ALL.iter().map(|op| op.as_str()).collect();
    assert_eq!(ours, theirs, "the seam and the contract must name the same ops");
}

#[test]
fn every_effect_matches_the_contracts_table() {
    for theirs in contract::Op::ALL {
        let ours = Op::parse(theirs.as_str()).expect("the op exists here (see the test above)");
        let expected = match theirs.effect() {
            contract::Effect::ReadOnly => Effect::ReadOnly,
            contract::Effect::WritesFiles => Effect::WritesFiles,
            contract::Effect::Network => Effect::Network,
        };
        assert_eq!(ours.effect(), expected, "{} is not the effect the contract states", theirs.as_str());
    }
}

#[test]
fn every_op_keeps_its_tool_name() {
    for op in Op::ALL {
        let theirs = contract::Op::parse(op.as_str()).expect("the op exists in the contract");
        assert_eq!(op.tool(), theirs.tool(), "{} is called by another tool in the contract", op.as_str());
    }
}
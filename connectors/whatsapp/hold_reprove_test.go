// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"testing"
)

// 29/10: a DM held since a PN/LID-mismatched revoke kept its voice notes unposted for
// days. The journal proves the hold when every recorded mutation names a message of
// that chat by the same author; reprove-holds swaps such a hold for exact fences.
func TestReproveHoldsReplacesOnlyJournalProvenHoldsAndPostsLaterAudio(t *testing.T) {
	j := wideFixture(t)
	activate(t, j)
	c, _ := j.Config()
	in := func(chat, id, sender string, sent int64) {
		m := audio(id, false, sent)
		m.Chat, m.Sender = chat, sender
		if err := j.ingest(m); err != nil {
			t.Fatal(err)
		}
	}
	revoke := func(chat, sender, target string) {
		if err := j.ingest(Message{ID: "r-" + chat + target, Chat: chat, Sender: sender, Target: target, Mutation: "revoke", MutationScope: false, ScopeProof: "remote_mismatch"}); err != nil {
			t.Fatal(err)
		}
	}
	// A: the 29/10 case, revoked message journaled in the chat by its author.
	in("900@lid", "a-target", "900@lid", 110)
	revoke("900@lid", "900@lid", "a-target")
	// B: target never journaled in this chat.
	revoke("901@lid", "901@lid", "b-elsewhere")
	// C: someone else revoked a message they did not write.
	in("902@g.us", "c-target", "300@s.whatsapp.net", 110)
	revoke("902@g.us", "301@s.whatsapp.net", "c-target")
	// D: one proven mutation and one unproven in the same chat: stays held.
	in("903@lid", "d-target", "903@lid", 110)
	revoke("903@lid", "903@lid", "d-target")
	revoke("903@lid", "903@lid", "d-missing")
	// E: legacy hold with no recorded evidence; F: owner clear (compute hold).
	j.db.Exec("INSERT INTO chat_holds VALUES(?,?,'904@lid',?)", c.Account, c.Generation, postingOnlyHold)
	j.db.Exec("INSERT INTO chat_holds VALUES(?,?,'905@lid','owner_chat_clear_hold')", c.Account, c.Generation)
	if count(t, j, "SELECT count(*) FROM chat_holds") != 6 {
		t.Fatal("fixture holds")
	}
	dry, err := j.reproveHolds(c, false)
	if err != nil {
		t.Fatal(err)
	}
	want := reproveReport{Reproved: 1, Fenced: 1, SkippedOtherHold: 1, SkippedLegacy: 1, SkippedTargetMissing: 2, SkippedAuthor: 1}
	if dry != want {
		t.Fatalf("%+v", dry)
	}
	if count(t, j, "SELECT count(*) FROM chat_holds") != 6 || count(t, j, "SELECT count(*) FROM source_blocks") != 0 {
		t.Fatal("dry run wrote")
	}
	got, err := j.reproveHolds(c, true)
	want.Applied = true
	if err != nil || got != want {
		t.Fatalf("%+v %v", got, err)
	}
	if count(t, j, "SELECT count(*) FROM chat_holds WHERE chat='900@lid'") != 0 || count(t, j, "SELECT count(*) FROM chat_holds") != 5 {
		t.Fatal("wrong holds released")
	}
	if count(t, j, "SELECT count(*) FROM source_blocks WHERE chat='900@lid' AND id='a-target' AND reason='verified_source_revoke_journal_reproof'") != 1 {
		t.Fatal("revoked target not fenced exactly")
	}
	if s, _ := audioState(t, j, "a-target"); s != "blocked_source" {
		t.Fatal("revoked audio unfenced", s)
	}
	if count(t, j, "SELECT count(*) FROM events WHERE kind='hold_reproved' AND detail='holds=1 fences=1'") != 1 {
		t.Fatal("event missing")
	}
	// Idempotent; and the chat's next voice note is transcribed AND posted.
	again, err := j.reproveHolds(c, true)
	if err != nil || again.Reproved != 0 {
		t.Fatalf("%+v %v", again, err)
	}
	in("900@lid", "a-next", "900@lid", 130)
	in("903@lid", "d-next", "903@lid", 130)
	drain(t, j, &recognizer{text: "fixture"})
	if s, reason := audioState(t, j, "a-next"); s != "transcribed" || reason != "" {
		t.Fatal(s, reason)
	}
	if s, reason := audioState(t, j, "d-next"); s != "transcribed" || reason != "posting_held_chat" {
		t.Fatal("still-held chat changed", s, reason)
	}
	f := &fakeTransport{}
	for i := 0; i < 4; i++ {
		j.post(context.Background(), f)
	}
	if f.sent != 1 || count(t, j, "SELECT count(*) FROM outbox WHERE chat='900@lid' AND source='a-next'") != 1 || count(t, j, "SELECT count(*) FROM outbox WHERE chat!='900@lid'") != 0 {
		t.Fatal("posting after reproof", f.sent)
	}
}

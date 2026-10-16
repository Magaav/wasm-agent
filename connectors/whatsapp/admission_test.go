package main

import (
	"context"
	"testing"
)

type readinessMutation struct {
	fakeTransport
	j *Journal
}

func (f *readinessMutation) Ready(_ Config, m Message) error {
	return f.j.ingest(Message{Chat: m.Chat, Target: m.ID, Sender: m.Sender, Mutation: "edit", MutationScope: true})
}
func TestReadinessMutationCommitsBeforeFinalDispatchAdmission(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	j.ingest(audio("race", false, 110))
	f := &readinessMutation{j: j}
	j.processAudio(context.Background(), f, &recognizer{text: "not to be sent"})
	if err := j.post(context.Background(), f); err != nil {
		t.Fatal(err)
	}
	if f.sent != 0 || count(t, j, "SELECT count(*) FROM outbox WHERE state='blocked'") != 1 || count(t, j, "SELECT count(*) FROM outbox WHERE state='unknown'") != 0 {
		t.Fatal("readiness mutation was deadlocked or dispatched")
	}
}

type proofNoSubmission struct {
	fakeTransport
	calls int
}

func (f *proofNoSubmission) Send(context.Context, string, string, string, Message) (string, error) {
	f.calls++
	return "", noSubmission("disconnected_before_dispatch", false)
}
func TestTypedNoSubmitProofRetriesWithoutResettingHistoricalUnknown(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	j.ingest(audio("proof", false, 110))
	f := &proofNoSubmission{}
	j.processAudio(context.Background(), f, &recognizer{text: "fixture"})
	j.db.Exec("INSERT INTO outbox(account,generation,chat,source,part,body,send_id,state) VALUES('100@s.whatsapp.net',1,'200@s.whatsapp.net','historical',0,'fixture','old-unknown','unknown')")
	if err := j.post(context.Background(), f); err != nil {
		t.Fatal(err)
	}
	j.post(context.Background(), f)
	if f.calls != 1 || count(t, j, "SELECT count(*) FROM outbox WHERE state='unknown'") != 1 || count(t, j, "SELECT count(*) FROM outbox WHERE state='ready' AND ack='definite_not_submitted_after_intent'") != 1 || count(t, j, "SELECT count(*) FROM events WHERE kind='definite_not_submitted'") != 1 {
		t.Fatal("no-submit proof or historical uncertainty misclassified")
	}
}

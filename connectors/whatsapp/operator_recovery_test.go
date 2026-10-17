// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"testing"
	"time"
)

func TestOperatorUnknownCannotBeEscapedByNewGeneration(t *testing.T) {
	j, r, f := operatorFixture(t)
	i := approvedOperator(t, j, r, f)
	if _, err := j.db.Exec("UPDATE operator_intents SET state='unknown' WHERE id=?", i.ID); err != nil {
		t.Fatal(err)
	}
	c, _ := j.Config()
	c.Generation++
	if err := j.save(c); err != nil {
		t.Fatal(err)
	}
	r.Generation = c.Generation
	r.Body = "new generation must not replay uncertainty"
	if err := j.ingest(Message{Chat: r.Chat, ID: "gen2-source", Sender: r.Chat, Body: "new source", Sent: 102}); err != nil {
		t.Fatal(err)
	}
	if _, err := j.prepareOperator(r, r.Chat, r.Chat, f.NewID); err == nil {
		t.Fatal("generation bypassed old unknown")
	}
	status, err := j.status()
	if err != nil || status["operator_unknown_sends_all_generations"] != 1 {
		t.Fatal(status, err)
	}
	if f.calls.Load() != 0 {
		t.Fatal("cross-generation fixture invoked transport")
	}
}
func TestOperatorExpiredPreparationAndIndependentHolds(t *testing.T) {
	j, r, f := operatorFixture(t)
	i := approvedOperator(t, j, r, f)
	if _, err := j.db.Exec("UPDATE operator_intents SET prepared=? WHERE id=?", time.Now().Unix()-601, i.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := j.sendOperator(context.Background(), statusRequest(i), f); err == nil || f.calls.Load() != 0 {
		t.Fatal("expired approval sent")
	}
	re := preparedOperator(t, j, r, f)
	if re.State != "prepared" || re.SendID != i.SendID || re.Digest == i.Digest {
		t.Fatal(re)
	}
	// An independent text can really dispatch with a pre-existing historical hold,
	// without changing the held source/old transcript outbox or activation policy.
	if err := j.mutate(Config{Account: r.Account, Generation: r.Generation}, Message{Chat: r.Chat, Mutation: "delete", Target: "historical"}); err != nil {
		t.Fatal(err)
	}
	re = approvedOperator(t, j, r, f)
	out, err := j.sendOperator(context.Background(), statusRequest(re), f)
	if err != nil || out.State != "accepted" {
		t.Fatal(out, err)
	}
	if count(t, j, "SELECT count(*) FROM chat_holds") != 1 {
		t.Fatal("historical hold cleared")
	}
	c, _ := j.Config()
	if c.Requested || c.Activated != 0 || c.Language != "en" {
		t.Fatal("operator path modified transcript policy", c)
	}
}

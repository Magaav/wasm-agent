// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

// Deterministic receipt fixtures against the ACTUAL pinned SDK types
// (go.mau.fi/whatsmeow/types + types/events) with real SQLite/HTTP boundaries.
// All sends are fakes; no real account, network or device is touched.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

func deliveredEvent(chat types.JID, id string) *events.Receipt {
	return &events.Receipt{MessageSource: types.MessageSource{Chat: chat, Sender: chat}, MessageIDs: []types.MessageID{id}, Type: types.ReceiptTypeDelivered, Timestamp: time.Unix(300, 0)}
}

func acceptedOperatorIntent(t *testing.T, j *Journal, r operatorRequest, f *operatorFake) operatorIntent {
	t.Helper()
	i := approvedOperator(t, j, r, f)
	i, err := j.sendOperator(context.Background(), statusRequest(i), f)
	if err != nil || i.State != "accepted" {
		t.Fatalf("accepted intent fixture: %v %v", i, err)
	}
	return i
}

func receiptCounters(t *testing.T, j *Journal) map[string]any {
	t.Helper()
	s, err := j.status()
	if err != nil {
		t.Fatal(err)
	}
	m, ok := s["operator_recipient_receipts"].(map[string]any)
	if !ok {
		t.Fatalf("receipt diagnostics missing: %v", s)
	}
	return m
}

func TestReceiptEventAdvancesExactIntentDeliveryThenReadWithoutResend(t *testing.T) {
	j, r, f := operatorFixture(t)
	i := acceptedOperatorIntent(t, j, r, f)
	chat := types.NewJID("200", types.DefaultUserServer)
	a := fixtureAdapter(t, j)
	if !a.event(deliveredEvent(chat, i.SendID)) {
		t.Fatal("receipt event reported failure")
	}
	got, err := readOperator(j.db, i.ID)
	if err != nil || got.DeliveredAt <= 0 || got.ReadAt != 0 || !strings.Contains(got.ReceiptBasis, "delivery") {
		t.Fatalf("delivery not recorded: %v %v", got, err)
	}
	if delivery, read := operatorReceiptStates(got.DeliveredAt, got.ReadAt); delivery != "delivered" || read != "unknown" {
		t.Fatalf("reported %s/%s", delivery, read)
	}
	// A duplicate delivered receipt is idempotent: one history row, no rewrite.
	if !a.event(deliveredEvent(chat, i.SendID)) {
		t.Fatal("duplicate receipt reported failure")
	}
	if n := count(t, j, "SELECT count(*) FROM operator_receipts"); n != 1 {
		t.Fatalf("history rows=%d", n)
	}
	// Read receipt advances only the read dimension.
	read := deliveredEvent(chat, i.SendID)
	read.Type = types.ReceiptTypeRead
	if !a.event(read) {
		t.Fatal("read receipt reported failure")
	}
	got, err = readOperator(j.db, i.ID)
	if err != nil || got.ReadAt <= 0 || got.DeliveredAt <= 0 {
		t.Fatalf("read not recorded: %v %v", got, err)
	}
	if delivery, r2 := operatorReceiptStates(got.DeliveredAt, got.ReadAt); delivery != "delivered" || r2 != "read" {
		t.Fatalf("reported %s/%s", delivery, r2)
	}
	if f.calls.Load() != 1 {
		t.Fatalf("receipt path sent again: %d", f.calls.Load())
	}
	status := receiptCounters(t, j)
	if status["delivered_observed"].(int) != 1 || status["read_observed"].(int) != 1 || status["accepted_awaiting_receipt"].(int) != 0 {
		t.Fatalf("aggregates %v", status)
	}
}

func TestReceiptReadWithoutDeliveryStaysHonestlyPartial(t *testing.T) {
	j, r, f := operatorFixture(t)
	i := acceptedOperatorIntent(t, j, r, f)
	read := deliveredEvent(types.NewJID("200", types.DefaultUserServer), i.SendID)
	read.Type = types.ReceiptTypeRead
	j.observeReceipt(read)
	got, err := readOperator(j.db, i.ID)
	if err != nil || got.ReadAt <= 0 || got.DeliveredAt != 0 || !strings.Contains(got.ReceiptBasis, "read") {
		t.Fatalf("read-without-delivery misreported: %v %v", got, err)
	}
	if delivery, r2 := operatorReceiptStates(got.DeliveredAt, got.ReadAt); delivery != "unknown" || r2 != "read" {
		t.Fatalf("reported %s/%s", delivery, r2)
	}
}

func TestReceiptWrongChatIDAccountAndGenerationNeverAdvance(t *testing.T) {
	j, r, f := operatorFixture(t)
	i := acceptedOperatorIntent(t, j, r, f)
	other := deliveredEvent(types.NewJID("201", types.DefaultUserServer), i.SendID)
	j.observeReceipt(other)
	unknownID := deliveredEvent(types.NewJID("200", types.DefaultUserServer), "never-dispatched-id")
	j.observeReceipt(unknownID)
	if got, _ := readOperator(j.db, i.ID); got.DeliveredAt != 0 || got.ReadAt != 0 {
		t.Fatalf("wrong chat/ID advanced: %v", got)
	}
	if n := count(t, j, "SELECT count(*) FROM operator_intents"); n != 1 {
		t.Fatalf("unmatched receipt invented an intent: %d", n)
	}
	if receiptCounters(t, j)["unmatched_receipts"].(int) != 2 {
		t.Fatal("unmatched receipts not surfaced")
	}
	// Wrong generation: same exact chat and message ID, other config generation.
	c, _ := j.Config()
	c.Generation = 2
	if err := j.save(c); err != nil {
		t.Fatal(err)
	}
	j.observeReceipt(deliveredEvent(types.NewJID("200", types.DefaultUserServer), i.SendID))
	if got, _ := readOperator(j.db, i.ID); got.DeliveredAt != 0 {
		t.Fatalf("wrong generation advanced: %v", got)
	}
	// Wrong account: the intent belongs to the previous account.
	c.Account = "101@s.whatsapp.net"
	c.Generation = 1
	if err := j.save(c); err != nil {
		t.Fatal(err)
	}
	j.observeReceipt(deliveredEvent(types.NewJID("200", types.DefaultUserServer), i.SendID))
	if got, _ := readOperator(j.db, i.ID); got.DeliveredAt != 0 {
		t.Fatalf("wrong account advanced: %v", got)
	}
}

func TestReceiptsDisabledAndEveryOtherSDKTypeStayUnknown(t *testing.T) {
	j, r, f := operatorFixture(t)
	i := acceptedOperatorIntent(t, j, r, f)
	chat := types.NewJID("200", types.DefaultUserServer)
	before := receiptCounters(t, j)["ignored_receipts"].(int)
	for _, kind := range []types.ReceiptType{
		types.ReceiptTypeReadSelf, // reader disabled read receipts: official apps hide it
		types.ReceiptTypeSender,   // OUR other device, not the recipient
		types.ReceiptTypeInactive,
		types.ReceiptTypeRetry,
		types.ReceiptTypePlayed,
		types.ReceiptTypeServerError,
		types.ReceiptTypePeerMsg,
		types.ReceiptTypeHistorySync,
	} {
		e := deliveredEvent(chat, i.SendID)
		e.Type = kind
		j.observeReceipt(e)
	}
	got, err := readOperator(j.db, i.ID)
	if err != nil || got.DeliveredAt != 0 || got.ReadAt != 0 {
		t.Fatalf("non-delivery receipt advanced: %v %v", got, err)
	}
	if after := receiptCounters(t, j)["ignored_receipts"].(int); after-before != 8 {
		t.Fatalf("ignored counter %d->%d", before, after)
	}
	if f.calls.Load() != 1 {
		t.Fatalf("receipt path sent again: %d", f.calls.Load())
	}
}

func TestReceiptNeverSettlesOrResendsAnUnresolvedIntent(t *testing.T) {
	j, r, f := operatorFixture(t)
	f.err = errors.New("generic ACK lost")
	i := approvedOperator(t, j, r, f)
	unresolved, err := j.sendOperator(context.Background(), statusRequest(i), f)
	if err != nil || unresolved.State != "unknown" {
		t.Fatalf("fixture: %v %v", unresolved, err)
	}
	chat := types.NewJID("200", types.DefaultUserServer)
	j.observeReceipt(deliveredEvent(chat, i.SendID))
	read := deliveredEvent(chat, i.SendID)
	read.Type = types.ReceiptTypeRead
	j.observeReceipt(read)
	got, err := readOperator(j.db, i.ID)
	if err != nil || got.State != "unknown" || got.DeliveredAt != 0 || got.ReadAt != 0 {
		t.Fatalf("receipt settled an unresolved intent: %v %v", got, err)
	}
	if _, err = j.sendOperator(context.Background(), statusRequest(i), f); err != nil || f.calls.Load() != 1 {
		t.Fatalf("unresolved intent resent: %v %d", err, f.calls.Load())
	}
}

func TestReceiptPersistenceFailureIsVisibleNotStickyAndRetryable(t *testing.T) {
	j, r, f := operatorFixture(t)
	i := acceptedOperatorIntent(t, j, r, f)
	if _, err := j.db.Exec("CREATE TRIGGER refuse_receipt BEFORE UPDATE ON operator_intents BEGIN SELECT RAISE(ABORT,'private injected receipt failure'); END"); err != nil {
		t.Fatal(err)
	}
	j.observeReceipt(deliveredEvent(types.NewJID("200", types.DefaultUserServer), i.SendID))
	if got, _ := readOperator(j.db, i.ID); got.DeliveredAt != 0 || got.State != "accepted" {
		t.Fatalf("failed projection still advanced: %v", got)
	}
	if j.hasGap() {
		t.Fatal("receipt failure created a sticky persistence gap")
	}
	if receiptCounters(t, j)["persistence_failures"].(int) < 1 {
		t.Fatal("receipt failure not surfaced")
	}
	if _, err := j.db.Exec("DROP TRIGGER refuse_receipt"); err != nil {
		t.Fatal(err)
	}
	// An upstream re-delivered receipt after the failure is projected honestly.
	j.observeReceipt(deliveredEvent(types.NewJID("200", types.DefaultUserServer), i.SendID))
	if got, _ := readOperator(j.db, i.ID); got.DeliveredAt <= 0 {
		t.Fatalf("retry did not project: %v", got)
	}
}

func TestReceiptsSurviveReopenAndHistoryEvictionIsBounded(t *testing.T) {
	j, r, f := operatorFixture(t)
	i := acceptedOperatorIntent(t, j, r, f)
	chat := types.NewJID("200", types.DefaultUserServer)
	j.observeReceipt(deliveredEvent(chat, i.SendID))
	read := deliveredEvent(chat, i.SendID)
	read.Type = types.ReceiptTypeRead
	j.observeReceipt(read)
	dir := j.dir
	j.Close()
	restarted, err := openJournal(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	got, err := readOperator(restarted.db, i.ID)
	if err != nil || got.DeliveredAt <= 0 || got.ReadAt <= 0 {
		t.Fatalf("receipt state did not survive reopen: %v %v", got, err)
	}
	if n := count(t, restarted, "SELECT count(*) FROM operator_receipts"); n != 2 {
		t.Fatalf("history rows after reopen=%d", n)
	}
	restarted.mu.Lock()
	restarted.verified, restarted.authenticated = true, true
	restarted.mu.Unlock()
	second := r
	second.Body = "second independent text"
	i2 := acceptedOperatorIntent(t, restarted, second, f)
	if _, err := restarted.db.Exec("DELETE FROM operator_receipts"); err != nil {
		t.Fatal(err)
	}
	for n := 0; n < operatorReceiptHistoryLimit+5; n++ {
		if _, err := restarted.db.Exec("INSERT INTO operator_receipts(intent,account,generation,chat,send_id,state,at,basis) VALUES(?,?,?,?,?,?,'old','old')", fmt.Sprintf("synthetic-%d", n), i.Account, i.Generation, i.Chat, fmt.Sprintf("synthetic-id-%d", n), "delivered"); err != nil {
			t.Fatal(err)
		}
	}
	restarted.observeReceipt(deliveredEvent(chat, i2.SendID))
	var total, ours int
	if err := restarted.db.QueryRow("SELECT count(*) FROM operator_receipts").Scan(&total); err != nil {
		t.Fatal(err)
	}
	if err := restarted.db.QueryRow("SELECT count(*) FROM operator_receipts WHERE send_id=?", i2.SendID).Scan(&ours); err != nil {
		t.Fatal(err)
	}
	if total > operatorReceiptHistoryLimit || ours != 1 {
		t.Fatalf("eviction total=%d ours=%d", total, ours)
	}
	if got, _ := readOperator(restarted.db, i2.ID); got.DeliveredAt <= 0 {
		t.Fatal("eviction lost the durable per-intent state")
	}
}

func TestConcurrentReceiptsAndStatusReadsStayConsistent(t *testing.T) {
	j, r, f := operatorFixture(t)
	i := acceptedOperatorIntent(t, j, r, f)
	chat := types.NewJID("200", types.DefaultUserServer)
	var wg sync.WaitGroup
	for n := 0; n < 6; n++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			j.observeReceipt(deliveredEvent(chat, i.SendID))
		}()
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := j.operatorStatus(statusRequest(i)); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	got, err := readOperator(j.db, i.ID)
	if err != nil || got.DeliveredAt <= 0 || got.ReadAt != 0 {
		t.Fatalf("concurrent receipts inconsistent: %v %v", got, err)
	}
	if n := count(t, j, "SELECT count(*) FROM operator_receipts"); n != 1 {
		t.Fatalf("concurrent duplicates wrote %d rows", n)
	}
}

func TestReceiptHTTPResponseCarriesStateKnownAtReturn(t *testing.T) {
	j, r, f := operatorFixture(t)
	a := operatorAuthority{Account: r.Account, Generation: r.Generation, Chats: []string{r.Chat}, Dispatch: strings.Repeat("d", 64), Approval: strings.Repeat("a", 64)}
	server := httptest.NewServer(operatorAPI(j, api(j, strings.Repeat("b", 64)), a, f))
	defer server.Close()
	call := func(path, key string, body any) (int, map[string]any) {
		t.Helper()
		b, _ := json.Marshal(body)
		req, _ := http.NewRequest("POST", server.URL+path, bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+key)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		if err = json.NewDecoder(resp.Body).Decode(&out); err != nil {
			t.Fatal(err)
		}
		return resp.StatusCode, out
	}
	i := preparedOperator(t, j, r, f)
	if code, out := call("/operator/approve", a.Approval, approvalRequest(i)); code != 200 {
		t.Fatalf("approve %d %v", code, out)
	}
	code, out := call("/operator/send", a.Dispatch, statusRequest(i))
	if code != 200 || out["recipient_delivery"] != "unknown" || out["recipient_read"] != "unknown" {
		t.Fatalf("send response claimed a receipt it never observed: %d %v", code, out)
	}
	j.observeReceipt(deliveredEvent(types.NewJID("200", types.DefaultUserServer), i.SendID))
	code, out = call("/operator/status", a.Dispatch, statusRequest(i))
	if code != 200 || out["recipient_delivery"] != "delivered" || out["recipient_read"] != "unknown" {
		t.Fatalf("status did not report observed delivery: %d %v", code, out)
	}
	// A duplicate confirmed intent returns its real status and never resends.
	code, out = call("/operator/send", a.Dispatch, statusRequest(i))
	if code != 200 || out["recipient_delivery"] != "delivered" || f.calls.Load() != 1 {
		t.Fatalf("duplicate send %d %v calls=%d", code, out, f.calls.Load())
	}
}

func TestOwnEchoAndElapsedTimeNeverBecomeDelivery(t *testing.T) {
	j, r, f := operatorFixture(t)
	f.err = errors.New("generic ACK lost")
	i := approvedOperator(t, j, r, f)
	if _, err := j.sendOperator(context.Background(), statusRequest(i), f); err != nil {
		t.Fatal(err)
	}
	if err := j.ingest(Message{ID: i.SendID, Chat: i.Chat, Sender: i.Chat, Body: i.Body, Own: true, Sent: 101}); err != nil {
		t.Fatal(err)
	}
	got, err := j.operatorStatus(statusRequest(i))
	if err != nil || got.State != "echo_confirmed" {
		t.Fatalf("echo status %v %v", got, err)
	}
	if got.DeliveredAt != 0 || got.ReadAt != 0 {
		t.Fatalf("echo/time became delivery: %v", got)
	}
	if delivery, read := operatorReceiptStates(got.DeliveredAt, got.ReadAt); delivery != "unknown" || read != "unknown" {
		t.Fatalf("reported %s/%s", delivery, read)
	}
}

func TestReceiptMigrationPreservesPreReceiptJournal(t *testing.T) {
	j := fixture(t)
	if _, err := j.db.Exec("DROP TABLE operator_receipts"); err != nil {
		t.Fatal(err)
	}
	if _, err := j.db.Exec("UPDATE operator_intents SET receipt_delivered=0,receipt_read=0,receipt_basis=''"); err != nil {
		t.Fatal(err)
	}
	// Re-running the additive install/migration on an existing journal is safe.
	if err := installOperator(j.db); err != nil {
		t.Fatal(err)
	}
	if _, err := j.db.Exec("INSERT INTO operator_receipts(intent,account,generation,chat,send_id,state,at,basis) VALUES('fixture',?,'1','chat','id','delivered',1,'observed')", "100@s.whatsapp.net"); err != nil {
		t.Fatalf("migrated table unusable: %v", err)
	}
}

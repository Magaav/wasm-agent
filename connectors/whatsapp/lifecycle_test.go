package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"

	waBinary "go.mau.fi/whatsmeow/binary"
	"go.mau.fi/whatsmeow/proto/waAdv"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

func lifecycleAPI(t *testing.T, j *Journal, path string, generation int64) *httptest.ResponseRecorder {
	t.Helper()
	c, _ := j.Config()
	b, _ := json.Marshal(readRequest{Account: c.Account, Generation: generation})
	req := httptest.NewRequest("POST", path, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer synthetic")
	out := httptest.NewRecorder()
	api(j, "synthetic").ServeHTTP(out, req)
	return out
}
func TestLogoutCannotResurrectIdentityBeforeSDKDeletion(t *testing.T) {
	j := fixture(t)
	a := fixtureAdapter(t, j)
	activate(t, j)
	if !a.event(&events.Connected{}) {
		t.Fatal("synthetic connected callback")
	}
	if lifecycleAPI(t, j, "/lookup_self", 1).Code != 200 {
		t.Fatal("initial synthetic identity")
	}
	if _, err := j.db.Exec("INSERT INTO outbox(account,generation,chat,source,part,body,send_id,state) VALUES('100@s.whatsapp.net',1,'200@s.whatsapp.net','held',0,'synthetic','held-id','unknown')"); err != nil {
		t.Fatal(err)
	}
	// Keep SDK ID deliberately present: actual SDK dispatches LoggedOut in a
	// goroutine BEFORE Delete completes, and Delete errors retain the ID.
	if !a.event(&events.LoggedOut{OnConnect: true, Reason: events.ConnectFailureMainDeviceGone}) {
		t.Fatal("logout persistence")
	}
	j.mu.Lock()
	cleared := !j.verified && !j.authenticated
	j.mu.Unlock()
	if !cleared {
		t.Fatal("logout did not immediately clear positive observations")
	}
	c, _ := j.Config()
	if c.Generation != 2 || !c.PairingRequired || c.Requested || c.Activated != 0 {
		t.Fatal(c)
	}
	if a.client.Store.ID == nil || a.client.Store.ID.ToNonAD().String() != c.Account {
		t.Fatal("causal precondition lost")
	}
	legacyLocalIDRule := a.client.Store.ID != nil && a.client.Store.ID.ToNonAD().String() == c.Account
	if !legacyLocalIDRule {
		t.Fatal("old identity-rule causal control lost")
	}
	// Old identity() checked ONLY this retained SDK/account match and set verified=true.
	if err := a.identity(); err == nil || err.Error() != "needs_pairing" {
		t.Fatal("stale identity resurrected", err)
	}
	if lifecycleAPI(t, j, "/lookup_self", 1).Code != 403 || lifecycleAPI(t, j, "/lookup_self", 2).Code != 409 {
		t.Fatal("scope/identity stale success")
	}
	if a.event(&events.Connected{}) || a.event(&events.OfflineSyncCompleted{}) {
		t.Fatal("late event revived logged-out session")
	}
	if err := a.completePair(1); err == nil || !strings.Contains(err.Error(), "generation_changed") {
		t.Fatal("late pair completion cleared newer logout", err)
	}
	if count(t, j, "SELECT count(*) FROM outbox WHERE state='unknown'") != 1 {
		t.Fatal("unknown reset")
	}
	s, err := j.status()
	if err != nil {
		t.Fatal(err)
	}
	obs := s["session_observation"].(map[string]any)
	l := obs["last_logout"].(Lifecycle)
	if l.ReasonCode != 403 || l.ReasonClass != "main_device_gone" || !l.OnConnect || l.Generation != 2 || l.At < 1 {
		t.Fatal(l)
	}
	if obs["authentication"] != "not_authenticated" {
		t.Fatal(obs)
	}
}
func TestLogoutFenceAndTypedDiagnosticsSurviveRestartWithoutKeyReadback(t *testing.T) {
	j := fixture(t)
	if err := j.loggedOut(events.ConnectFailureLoggedOut, false); err != nil {
		t.Fatal(err)
	}
	dir := j.dir
	j.Close()
	fresh, err := openJournal(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()
	s, err := fresh.status()
	if err != nil {
		t.Fatal(err)
	}
	o := s["session_observation"].(map[string]any)
	if o["runtime"] != "offline_cli" || o["local_identity"] != "unobserved" || o["authentication"] != "unobserved" {
		t.Fatal(o)
	}
	if o["last_logout"].(Lifecycle).OnConnect {
		t.Fatal("stream vs connect diagnostic lost")
	}
	a := fixtureAdapter(t, fresh)
	if a.identity() == nil {
		t.Fatal("restart accepted retained synthetic SDK ID")
	}
}
func TestActualSDKDisconnectPreservesSyntheticSavedPairButDoesNotAuthenticate(t *testing.T) {
	j := fixture(t)
	a := fixtureAdapter(t, j)
	// Synthetic SDK store only. No server/QR/protocol handshake is performed.
	a.client.Store.Account = &waAdv.ADVSignedDeviceIdentity{Details: []byte{1}, AccountSignature: make([]byte, 64), AccountSignatureKey: make([]byte, 32), DeviceSignature: make([]byte, 64)}
	a.client.Store.LID = types.NewJID("100", types.HiddenUserServer)
	if err := a.client.Store.Save(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := a.completePair(1); err != nil {
		t.Fatal(err)
	}
	if a.client.IsLoggedIn() {
		t.Fatal("no network login occurred")
	}
	out := lifecycleAPI(t, j, "/lookup_self", 1)
	if out.Code != 200 || !strings.Contains(out.Body.String(), `"authenticated_event_observed":false`) {
		t.Fatal(out.Body.String())
	}
	a.Close() // Actual pinned Disconnect+store Close, not Logout/Delete.
	reopened, err := newAdapter(context.Background(), j)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if reopened.client.Store.ID == nil || reopened.identity() != nil {
		t.Fatal("Disconnect deleted saved synthetic pairing")
	}
	s, err := j.status()
	if err != nil {
		t.Fatal(err)
	}
	o := s["session_observation"].(map[string]any)
	if o["authentication"] != "not_authenticated" || o["last_pair_success"].(Lifecycle).Event != "pair_success_local" {
		t.Fatal(o)
	}
}
func TestLifecycleProjectionNeverCopiesRawSDKContentOrUnknownReasonValues(t *testing.T) {
	j := fixture(t)
	a := fixtureAdapter(t, j)
	secret := "DO_NOT_DISCLOSE_SYNTHETIC_QR_TOKEN_HTTP_NODE"
	if !a.event(&events.ConnectFailure{Reason: events.ConnectFailureReason(7654321), Message: secret, Raw: &waBinary.Node{Tag: secret, Content: []byte(secret)}}) {
		t.Fatal("diagnostic persist")
	}
	if !a.event(&events.PairError{Error: errors.New(secret), BusinessName: secret, Platform: secret}) {
		t.Fatal("ignored raw pair event")
	}
	s, err := j.status()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(s)
	if bytes.Contains(b, []byte(secret)) || bytes.Contains(b, []byte("7654321")) {
		t.Fatal("raw lifecycle disclosure")
	}
	l := s["session_observation"].(map[string]any)["last_event"].(Lifecycle)
	if l.ReasonCode != 0 || l.ReasonClass != "unknown_or_not_applicable" {
		t.Fatal(l)
	}
	var details string
	if err = j.db.QueryRow("SELECT detail FROM events WHERE kind='connect_failure'").Scan(&details); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(details, secret) || strings.Contains(details, "7654321") {
		t.Fatal("durable raw disclosure")
	}
	// Even a damaged stored classification is not echoed as diagnostic data.
	j.db.Exec("UPDATE lifecycle SET value=?", fmt.Sprintf(`{"event":"connect_failure","at":1,"generation":1,"reason_code":401,"reason_class":%q}`, secret))
	s, err = j.status()
	if err != nil {
		t.Fatal(err)
	}
	b, _ = json.Marshal(s)
	if bytes.Contains(b, []byte(secret)) {
		t.Fatal("stored string echoed")
	}
	for _, event := range []string{"error", "timeout", "err-client-outdated", "err-scanned-without-multidevice", "err-unexpected-state"} {
		if pairingTerminalError(event) == nil {
			t.Fatal("missing named pairing refusal")
		}
	}
	if got := j.safePairCompletionError(errors.New(secret)); strings.Contains(got.Error(), secret) || !j.hasGap() {
		t.Fatal("unsafe completion error", got)
	}
}
func TestPairCompletionRequiresExactCurrentNondeletedSDKIdentity(t *testing.T) {
	j := fixture(t)
	a := fixtureAdapter(t, j)
	a.client.Store.ID = nil
	if err := a.completePair(1); err == nil || err.Error() != "pairing_identity_unproven" {
		t.Fatal("absent identity accepted", err)
	}
	id := types.NewJID("999", types.DefaultUserServer)
	a.client.Store.ID = &id
	if err := a.completePair(1); err == nil || err.Error() != "paired_account_mismatch" {
		t.Fatal("foreign identity accepted", err)
	}
	id = types.NewJID("100", types.DefaultUserServer)
	a.client.Store.Deleted = true
	if err := a.completePair(1); err == nil || err.Error() != "pairing_identity_unproven" {
		t.Fatal("deleted identity accepted", err)
	}
	if count(t, j, "SELECT count(*) FROM lifecycle") != 0 {
		t.Fatal("false pair-success record")
	}
}

func TestLifecycleFailureCannotRestoreVerifiedIdentityOrAdvancePartialGeneration(t *testing.T) {
	j := fixture(t)
	a := fixtureAdapter(t, j)
	a.identity()
	j.db.Exec("CREATE TRIGGER refuse_lifecycle BEFORE INSERT ON lifecycle BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
	if a.event(&events.LoggedOut{OnConnect: true, Reason: events.ConnectFailureUnknownLogout}) {
		t.Fatal("failed write reported success")
	}
	c, _ := j.Config()
	if c.Generation != 1 {
		t.Fatal("partial config commit", c)
	}
	if a.identity() == nil || lifecycleAPI(t, j, "/lookup_self", 1).Code == 200 || !j.hasGap() {
		t.Fatal("failed logout resurrected identity")
	}
}

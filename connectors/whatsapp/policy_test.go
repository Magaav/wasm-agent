package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/types/events"
)

type refusedTransport struct{ fakeTransport }

func (r *refusedTransport) Ready(Config, Message) error {
	return errors.New("definite pre-dispatch fixture refusal")
}
func TestDefiniteRefusalDistinctFromUnknown(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	j.ingest(audio("a", false, 110))
	transport := &refusedTransport{}
	j.processAudio(context.Background(), transport, &recognizer{text: "fixture"})
	j.post(context.Background(), transport)
	if transport.sent != 0 || count(t, j, "SELECT count(*) FROM outbox WHERE state='ready' AND ack LIKE 'definite%'") != 1 {
		t.Fatal("pre-dispatch refusal became a submitted send")
	}
}
func TestSharedAccountFenceAcrossStateDirectories(t *testing.T) {
	root := t.TempDir()
	one, e := openJournal(filepath.Join(root, "one"))
	if e != nil {
		t.Fatal(e)
	}
	defer one.Close()
	two, e := openJournal(filepath.Join(root, "two"))
	if e != nil {
		t.Fatal(e)
	}
	defer two.Close()
	owners := filepath.Join(root, "owners")
	if e = one.fence(owners, "fixture-account"); e != nil {
		t.Fatal(e)
	}
	if e = two.fence(owners, "fixture-account"); e == nil {
		t.Fatal("two state directories owned the same account")
	}
}
func TestLogoutGenerationPauseAndNoTextLoop(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	a, e := newAdapter(context.Background(), j)
	if e != nil {
		t.Fatal(e)
	}
	defer a.Close()
	a.event(&events.LoggedOut{})
	c, e := j.Config()
	if e != nil || c.Generation != 2 || c.Requested || c.Activated != 0 {
		t.Fatal("logout did not fence old generation", c, e)
	}
	if _, e = j.scope(c.Account, 1, c.Chats[0]); e == nil {
		t.Fatal("stale generation read")
	}
	j.ingest(Message{ID: "automated-text", Chat: c.Chats[0], Body: "🎙️ _Automated transcript_", Own: true, Sent: time.Now().Unix()})
	if count(t, j, "SELECT count(*) FROM audio") != 0 {
		t.Fatal("text feedback loop")
	}
}
func TestSnapshotTranscriptCursorAndNoRawKeys(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	for _, id := range []string{"a", "b", "c"} {
		j.ingest(audio(id, false, 110))
	}
	f := &fakeTransport{}
	r := &recognizer{text: "á synthetic transcript"}
	for i := 0; i < 3; i++ {
		j.processAudio(context.Background(), f, r)
	}
	token := strings.Repeat("b", 64)
	handler := api(j, token)
	request := func(before int64) map[string]any {
		b, _ := json.Marshal(map[string]any{"account": "100@s.whatsapp.net", "generation": 1, "conversation_id": "200@s.whatsapp.net", "limit": 2, "before": before})
		req := httptest.NewRequest("POST", "/read_snapshot", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code != 200 {
			t.Fatal(w.Code, w.Body.String())
		}
		if strings.Contains(w.Body.String(), "fixture audio") || strings.Contains(w.Body.String(), "raw") {
			t.Fatal("media keys/raw journal exposed")
		}
		var data map[string]any
		json.Unmarshal(w.Body.Bytes(), &data)
		return data
	}
	data := request(0)
	if data["truncated"] != true {
		t.Fatal("silent truncation")
	}
	rows := data["messages"].([]any)
	last := rows[1].(map[string]any)
	if last["transcript"] != "á synthetic transcript" {
		t.Fatal("cached transcript inaccessible")
	}
	older := request(int64(last["cursor"].(float64)))
	if len(older["messages"].([]any)) != 1 {
		t.Fatal("cursor lost history")
	}
}
func TestPrivateModelCacheAndRetirementAttestationRefusals(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "receipt.json")
	os.WriteFile(file, []byte(`{"schema":1,"account":"fixture","legacy_disabled":true,"unknowns_preserved":true,"identity_verified":false}`), 0600)
	if validateRetirement(file, "fixture") == nil {
		t.Fatal("unverified identity accepted")
	}
	if validateRetirement(file, "foreign") == nil {
		t.Fatal("foreign account accepted")
	}
	for _, bad := range []Config{{Account: "fixture", Generation: 1, Language: "pt", Mode: "translate", Chats: []string{"200@s.whatsapp.net"}}, {Account: "fixture", Generation: 1, Language: "de", Mode: "transcribe", Chats: []string{"200@s.whatsapp.net"}}} {
		if validConfig(bad) == nil {
			t.Fatal("unsupported mode/language")
		}
	}
}

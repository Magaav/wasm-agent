// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

func fixture(t *testing.T) *Journal {
	t.Helper()
	j, e := openJournal(t.TempDir())
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(j.Close)
	if e = j.save(Config{Account: "100@s.whatsapp.net", Generation: 1, Language: "en", Mode: "transcribe", Chats: []string{"200@s.whatsapp.net"}}); e != nil {
		t.Fatal(e)
	}
	return j
}
func activate(t *testing.T, j *Journal) {
	t.Helper()
	c, _ := j.Config()
	c.Requested = true
	c.Activated = 100
	c.TranscriptPosting = true
	j.save(c)
}
func audio(id string, own bool, sent int64) Message {
	return Message{ID: id, Chat: "200@s.whatsapp.net", Sender: "200@s.whatsapp.net", Sent: sent, Audio: true, Own: own, Raw: []byte("fixture")}
}

type fakeTransport struct {
	sent      int
	downloads int
	fail      bool
	mismatch  bool
	next      int
	bodies    []string
	ids       []string
}

func (f *fakeTransport) Download(ctx context.Context, m Message) ([]byte, error) {
	f.downloads++
	if m.ID == "bad" {
		return nil, errors.New("fixture_private_error")
	}
	return []byte("fixture audio"), nil
}
func (f *fakeTransport) NewID() string { f.next++; return fmt.Sprintf("synthetic-%d", f.next) }
func (f *fakeTransport) Send(ctx context.Context, chat, body, id string, source Message) (string, error) {
	f.sent++
	f.bodies = append(f.bodies, body)
	f.ids = append(f.ids, id)
	if f.fail {
		return "", errors.New("ack lost")
	}
	if f.mismatch {
		return "foreign-id", nil
	}
	return id, nil
}

type recognizer struct {
	calls int
	text  string
}

func (r *recognizer) Transcribe(context.Context, string, string) (string, error) {
	r.calls++
	return r.text, nil
}
func count(t *testing.T, j *Journal, sql string) int {
	t.Helper()
	var n int
	if e := j.db.QueryRow(sql).Scan(&n); e != nil {
		t.Fatal(e)
	}
	return n
}
func TestRestartOwnerDefaultsScope(t *testing.T) {
	dir := t.TempDir()
	j, e := openJournal(dir)
	if e != nil {
		t.Fatal(e)
	}
	c := Config{Account: "100@s.whatsapp.net", Generation: 1, Language: "en", Mode: "transcribe", Chats: []string{"200@s.whatsapp.net"}}
	if e = j.save(c); e != nil {
		t.Fatal(e)
	}
	if other, e := openJournal(dir); e == nil {
		other.Close()
		t.Fatal("second owner admitted")
	}
	if _, e = j.scope(c.Account, 2, c.Chats[0]); e == nil {
		t.Fatal("stale generation")
	}
	if _, e = j.scope("foreign", 1, c.Chats[0]); e == nil {
		t.Fatal("foreign account")
	}
	if _, e = j.scope(c.Account, 1, "300@s.whatsapp.net"); e == nil {
		t.Fatal("foreign chat")
	}
	c.Language = "pt"
	j.save(c)
	j.Close()
	j, e = openJournal(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer j.Close()
	c, e = j.Config()
	if e != nil || c.Language != "pt" || c.Requested {
		t.Fatal(c, e)
	}
	c.Mode = "translate"
	if j.save(c) == nil {
		t.Fatal("fake translation admitted")
	}
	c.Mode = "transcribe"
	c.Language = "xx"
	if j.save(c) == nil {
		t.Fatal("invalid language")
	}
}
func TestHistoryBothDirectionsDedupIndependentCompute(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	old := audio("old", false, 99)
	old.History = true
	j.ingest(old)
	j.ingest(audio("bad", false, 110))
	j.ingest(audio("outgoing", true, 120))
	j.ingest(audio("incoming", false, 130))
	j.ingest(audio("incoming", false, 130))
	unsupported := audio("once", true, 140)
	unsupported.Unsupported = "view_once"
	j.ingest(unsupported)
	f := &fakeTransport{}
	r := &recognizer{text: "Olá português 👋"}
	for i := 0; i < 4; i++ {
		if e := j.processAudio(context.Background(), f, r); e != nil {
			t.Fatal(e)
		}
	}
	if count(t, j, "SELECT count(*) FROM messages") != 5 || count(t, j, "SELECT count(*) FROM audio WHERE state='transcribed'") != 2 || r.calls != 2 {
		t.Fatal("ingest blocked, history flood, or duplicate compute", r.calls)
	}
	if count(t, j, "SELECT count(*) FROM audio WHERE state='pending'") != 1 {
		t.Fatal("retryable audio silently lost")
	}
	if count(t, j, "SELECT count(*) FROM audio WHERE state='unsupported'") != 1 {
		t.Fatal("view once not visible")
	}
	for i := 0; i < 3; i++ {
		j.post(context.Background(), f)
	}
	if f.sent != 2 {
		t.Fatal("both directions not posted", f.sent)
	}
	if !strings.HasPrefix(f.bodies[0], "🤖 _Copiloto_") {
		t.Fatal("missing marker")
	}
	c, _ := j.Config()
	c.Requested = false
	j.save(c)
	j.ingest(audio("paused-backlog", false, 150))
	j.processAudio(context.Background(), f, r)
	if r.calls != 2 {
		t.Fatal("explicit off ignored")
	}
	c.Requested = true
	j.save(c)
	j.processAudio(context.Background(), f, r)
	if r.calls != 3 {
		t.Fatal("post-activation backlog expired")
	}
}
func TestUnknownNeverReplayAndEchoReconciles(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	j.ingest(audio("a", false, 110))
	f := &fakeTransport{fail: true}
	r := &recognizer{text: strings.Repeat("á", 6000)}
	if e := j.processAudio(context.Background(), f, r); e != nil {
		t.Fatal(e)
	}
	j.post(context.Background(), f)
	j.post(context.Background(), f)
	if f.sent != 1 || count(t, j, "SELECT count(*) FROM outbox WHERE state='unknown'") != 1 {
		t.Fatal("ambiguous send replayed")
	}
	if count(t, j, "SELECT count(*) FROM outbox WHERE state='ready'") != 2 {
		t.Fatal("multipart not persisted")
	}
	echo := Message{ID: f.ids[0], Chat: "200@s.whatsapp.net", Body: "wrong", Own: true, Sent: 120}
	j.ingest(echo)
	if count(t, j, "SELECT count(*) FROM outbox WHERE state='unknown'") != 1 {
		t.Fatal("wrong body reconciled")
	}
	echo.ID = "foreign"
	echo.Body = f.bodies[0]
	j.ingest(echo)
	if count(t, j, "SELECT count(*) FROM outbox WHERE state='unknown'") != 1 {
		t.Fatal("wrong id reconciled")
	}
	echo.ID = f.ids[0]
	j.ingest(echo)
	if count(t, j, "SELECT count(*) FROM outbox WHERE state='confirmed'") != 1 {
		t.Fatal("exact echo did not reconcile")
	}
	f.fail = false
	j.post(context.Background(), f)
	if f.sent != 2 {
		t.Fatal("next part unavailable")
	}
	if r.calls != 1 {
		t.Fatal("cached transcript recomputed")
	}
}
func TestCrashIntentSurvivesRestart(t *testing.T) {
	dir := t.TempDir()
	j, e := openJournal(dir)
	if e != nil {
		t.Fatal(e)
	}
	j.save(Config{Account: "100@s.whatsapp.net", Generation: 1, Language: "en", Mode: "transcribe", Chats: []string{"200@s.whatsapp.net"}, Activated: 100, Requested: true, TranscriptPosting: true})
	j.ingest(audio("a", false, 110))
	f := &fakeTransport{}
	j.processAudio(context.Background(), f, &recognizer{text: "fixture"})
	j.db.Exec("UPDATE outbox SET state='reserved'")
	j.Close()
	j, e = openJournal(dir)
	if e != nil {
		t.Fatal(e)
	}
	defer j.Close()
	j.post(context.Background(), f)
	if f.sent != 0 || count(t, j, "SELECT count(*) FROM outbox WHERE state='unknown'") != 1 {
		t.Fatal("crash intent replayed")
	}
}
func TestAPIAuthenticationIsolationAndNoGeneralSend(t *testing.T) {
	j := fixture(t)
	j.ingest(audio("a", false, time.Now().Unix()))
	server := httptest.NewServer(api(j, strings.Repeat("a", 64)))
	defer server.Close()
	call := func(path, token, account string, generation int, chat string) int {
		b, _ := json.Marshal(map[string]any{"account": account, "generation": generation, "conversation_id": chat})
		req, _ := http.NewRequest("POST", server.URL+path, bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		resp, e := http.DefaultClient.Do(req)
		if e != nil {
			t.Fatal(e)
		}
		defer resp.Body.Close()
		return resp.StatusCode
	}
	token := strings.Repeat("a", 64)
	if call("/read_snapshot", "bad", "100@s.whatsapp.net", 1, "") != 401 {
		t.Fatal("auth bypass")
	}
	for _, c := range []struct {
		a    string
		g    int
		chat string
	}{{"foreign", 1, ""}, {"100@s.whatsapp.net", 2, ""}, {"100@s.whatsapp.net", 1, "300@s.whatsapp.net"}} {
		if call("/read_snapshot", token, c.a, c.g, c.chat) != 403 {
			t.Fatal("scope bypass")
		}
	}
	if call("/read_snapshot", token, "100@s.whatsapp.net", 1, "200@s.whatsapp.net") != 200 {
		t.Fatal("snapshot failed")
	}
	if call("/send_message", token, "100@s.whatsapp.net", 1, "200@s.whatsapp.net") != 403 {
		t.Fatal("general send enabled")
	}
	if call("/download_audio", token, "100@s.whatsapp.net", 1, "200@s.whatsapp.net") != 403 {
		t.Fatal("media auth-store exposure")
	}
}
func TestPinnedAdapterMappingsAndDeviceSQLite(t *testing.T) {
	j := fixture(t)
	a, e := newAdapter(context.Background(), j)
	if e != nil {
		t.Fatal(e)
	}
	defer a.Close()
	if a.client.Store.ID != nil {
		t.Fatal("fixture unexpectedly paired")
	}
	for _, own := range []bool{false, true} {
		event := &events.Message{Info: types.MessageInfo{MessageSource: types.MessageSource{Chat: types.NewJID("200", types.DefaultUserServer), Sender: types.NewJID("100", types.DefaultUserServer), IsFromMe: own}, ID: "fixture", Timestamp: time.Unix(100, 0)}, Message: &waE2E.Message{AudioMessage: &waE2E.AudioMessage{Mimetype: proto.String("audio/ogg"), FileLength: proto.Uint64(123)}}}
		m := mapMessage(event, true)
		if !m.Audio || m.Own != own || !m.History || len(m.Raw) == 0 {
			t.Fatal(m)
		}
		event.IsViewOnce = true
		m = mapMessage(event, false)
		if m.Unsupported != "view_once" || len(m.Raw) != 0 {
			t.Fatal("view once retained")
		}
	}
}
func TestWarmWorkerReuseAndMissingCache(t *testing.T) {
	python := os.Getenv("WA_TEST_PYTHON")
	if python == "" {
		t.Skip("WA_TEST_PYTHON required for real process fixture")
	}
	dir := t.TempDir()
	fixture := `import json,sys
for line in sys.stdin:
 r=json.loads(line)
 print(json.dumps({'ok':True,'transcript':r['language']+' fixture'}),flush=True)
`
	script := filepath.Join(dir, "fake-worker.py")
	os.WriteFile(script, []byte(fixture), 0600)
	w := &Worker{Python: python, Script: script, Cache: dir}
	defer w.Close()
	for _, lang := range []string{"en", "pt"} {
		text, e := w.Transcribe(context.Background(), "private.audio", lang)
		if e != nil || text != lang+" fixture" {
			t.Fatal(text, e)
		}
	}
	if w.cmd == nil {
		t.Fatal("worker not kept warm")
	}
	pid := w.cmd.Process.Pid
	w.Transcribe(context.Background(), "private.audio", "pt")
	if w.cmd.Process.Pid != pid {
		t.Fatal("worker rebuilt")
	}
	missing := &Worker{}
	if _, e := missing.Transcribe(context.Background(), "x", "en"); e == nil {
		t.Fatal("missing cache admitted")
	}
}
func TestPrivatePairingRefusesCapturedTTY(t *testing.T) {
	if privateTTY() {
		t.Skip("interactive test terminal")
	}
	if e := pair(context.Background(), nil); e == nil || !strings.Contains(e.Error(), "no_capture") {
		t.Fatal("captured QR permitted", e)
	}
}

type ocrFixture struct {
	calls int
	text  string
	fail  bool
}

func (o *ocrFixture) Recognize(ctx context.Context, path, language string) (string, error) {
	o.calls++
	if o.fail {
		return "", errors.New("fixture_ocr_failure")
	}
	return o.text, nil
}

func TestImageMediaIsOcredAndSearchable(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	j.ingest(Message{ID: "image-1", Chat: "200@s.whatsapp.net", Sender: "200@s.whatsapp.net", Sent: 130, MediaKind: "image", Raw: []byte("fixture image")})
	f := &fakeTransport{}
	o := &ocrFixture{text: "Texto do exame: colangiopancreatografia"}
	if err := j.processMedia(context.Background(), f, o); err != nil {
		t.Fatal(err)
	}
	if o.calls != 1 || f.downloads != 1 {
		t.Fatal("image was not downloaded and recognized exactly once", o.calls, f.downloads)
	}
	var state, text string
	if err := j.db.QueryRow("SELECT media_state,media_text FROM messages WHERE id='image-1'").Scan(&state, &text); err != nil {
		t.Fatal(err)
	}
	if state != "ocr_done" || !strings.Contains(text, "colangiopancreatografia") {
		t.Fatal("OCR text not journaled", state, text)
	}
	c, _ := j.Config()
	p, err := j.readPage(c, readRequest{Conversations: []string{"200@s.whatsapp.net"}, Query: "exame"}, "read_snapshot")
	if err != nil || !strings.Contains(fmt.Sprint(p), "colangiopancreatografia") {
		t.Fatal("OCR text not searchable through the read page", err)
	}
}

func TestTranscriptPostingToggleAndBothDirections(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	c, _ := j.Config()
	c.TranscriptPosting = false
	if err := j.save(c); err != nil {
		t.Fatal(err)
	}
	j.ingest(audio("in-off", false, 130))
	j.ingest(audio("own-off", true, 130))
	f := &fakeTransport{}
	r := &recognizer{text: "fixture"}
	for i := 0; i < 4; i++ {
		if err := j.processAudio(context.Background(), f, r); err != nil {
			t.Fatal(err)
		}
	}
	if count(t, j, "SELECT count(*) FROM outbox") != 0 {
		t.Fatal("posting toggle off still queued a reply")
	}
	if count(t, j, "SELECT count(*) FROM audio WHERE state='transcribed'") != 2 {
		t.Fatal("toggle off must still transcribe for the journal")
	}
	c, _ = j.Config()
	c.TranscriptPosting = true
	if err := j.save(c); err != nil {
		t.Fatal(err)
	}
	j.ingest(audio("in-on", false, 140))
	j.ingest(audio("own-on", true, 140))
	for i := 0; i < 4; i++ {
		if err := j.processAudio(context.Background(), f, r); err != nil {
			t.Fatal(err)
		}
	}
	if count(t, j, "SELECT count(*) FROM outbox WHERE source='in-on'") != 1 {
		t.Fatal("incoming audio was not queued when posting is enabled")
	}
	if count(t, j, "SELECT count(*) FROM outbox WHERE source='own-on'") != 1 {
		t.Fatal("own outgoing audio was not posted when posting is enabled")
	}
}

func TestReleaseHoldPreservesBlockedEvidenceAndProcessesNewAudio(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	if _, err := j.db.Exec("INSERT INTO chat_holds VALUES(?,?,?,?)", "100@s.whatsapp.net", 1, "200@s.whatsapp.net", "unproven_mutation_chat_hold"); err != nil {
		t.Fatal(err)
	}
	j.ingest(audio("blocked", false, 130))
	if count(t, j, "SELECT count(*) FROM audio WHERE id='blocked' AND state='blocked_source'") != 1 {
		t.Fatal("held audio was not fenced")
	}
	c, _ := j.Config()
	if err := j.releaseHold(c, "200@s.whatsapp.net", "reviewed unproven revoke"); err != nil {
		t.Fatal(err)
	}
	if count(t, j, "SELECT count(*) FROM chat_holds") != 0 {
		t.Fatal("hold was not released")
	}
	if count(t, j, "SELECT count(*) FROM audio WHERE id='blocked' AND state='blocked_source'") != 1 {
		t.Fatal("blocked evidence was replayed or rewritten")
	}
	if count(t, j, "SELECT count(*) FROM events WHERE kind='hold_released'") != 1 {
		t.Fatal("hold release was not recorded")
	}
	j.ingest(audio("after-release", false, 140))
	if count(t, j, "SELECT count(*) FROM audio WHERE id='after-release' AND state='pending'") != 1 {
		t.Fatal("new audio after release was not made pending")
	}
	if err := j.releaseHold(c, "200@s.whatsapp.net", "again"); err == nil || !strings.Contains(err.Error(), "chat_hold_not_found") {
		t.Fatal("missing hold was not refused", err)
	}
}

// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

// Legacy fixtures use 1970 timestamps; they test other rules, so the fresh
// window is unbounded for them. Freshness tests set it explicitly.
func TestMain(m *testing.M) {
	freshSeconds = 1 << 40
	os.Exit(m.Run())
}

func withFresh(t *testing.T, s int64) {
	t.Helper()
	old := freshSeconds
	freshSeconds = s
	t.Cleanup(func() { freshSeconds = old })
}

type notifier struct {
	chats, bodies []string
	fail          bool
}

func (n *notifier) Notify(ctx context.Context, chat, body string) error {
	if n.fail {
		return errors.New("offline")
	}
	n.chats = append(n.chats, chat)
	n.bodies = append(n.bodies, body)
	return nil
}

// Audio older than the window is never picked up: the sweep expires it and the
// own chat gets one log line. Fresh audio is transcribed and posted.
func TestStaleAudioExpiresWithAlertAndFreshAudioPosts(t *testing.T) {
	withFresh(t, 300)
	j := fixture(t)
	activate(t, j)
	now := time.Now().Unix()
	j.ingest(voice("old", now-301, 5))
	j.ingest(voice("new", now-10, 5))
	r := &recognizer{text: "olá"}
	drain(t, j, r)
	if r.calls != 1 {
		t.Fatal("stale audio was transcribed", r.calls)
	}
	if s, _ := audioState(t, j, "old"); s != "pending" {
		t.Fatal("pickup changed a stale row before the sweep", s)
	}
	if n, err := j.expireStale(now); err != nil || n != 1 {
		t.Fatal(n, err)
	}
	if s, reason := audioState(t, j, "old"); s != "expired" || reason != "stale_over_5m" {
		t.Fatal(s, reason)
	}
	if s, _ := audioState(t, j, "new"); s != "transcribed" {
		t.Fatal(s)
	}
	n := &notifier{}
	var last time.Time
	if sent, err := j.sendAlerts(context.Background(), n, &last); err != nil || !sent {
		t.Fatal(sent, err)
	}
	if len(n.chats) != 1 || n.chats[0] != "100@s.whatsapp.net" || !strings.Contains(n.bodies[0], "não transcrito em 5 min") || strings.Contains(n.bodies[0], "olá") {
		t.Fatal(n.chats, n.bodies)
	}
	// Rate limit, then nothing left to send.
	if sent, _ := j.sendAlerts(context.Background(), n, &last); sent {
		t.Fatal("second message inside the minute")
	}
	last = time.Time{}
	if sent, _ := j.sendAlerts(context.Background(), n, &last); sent {
		t.Fatal("alert resent")
	}
}

// A transcript part that is not dispatched within the window is never posted.
func TestStaleOutboxIsNotRepostedAndAlerts(t *testing.T) {
	withFresh(t, 300)
	j := fixture(t)
	activate(t, j)
	now := time.Now().Unix()
	j.ingest(voice("a", now-5, 5))
	drain(t, j, &recognizer{text: "texto"})
	if _, err := j.db.Exec("UPDATE outbox SET created=?", now-400); err != nil {
		t.Fatal(err)
	}
	f := &fakeTransport{}
	if err := j.post(context.Background(), f); err != nil || f.sent != 0 {
		t.Fatal("stale part dispatched", f.sent, err)
	}
	if n, err := j.expireStale(now); err != nil || n != 1 {
		t.Fatal(n, err)
	}
	if count(t, j, "SELECT count(*) FROM outbox WHERE state='expired'") != 1 || count(t, j, "SELECT count(*) FROM alerts WHERE kind='post_expired'") != 1 {
		t.Fatal("outbox not expired or no alert")
	}
}

// Audio transcribed into a held chat is logged (that is why a group shows no
// transcript); a failed decode that exhausts its tiers is logged too.
func TestHeldAndUnsupportedAudioAlert(t *testing.T) {
	withFresh(t, 300)
	j := fixture(t)
	activate(t, j)
	now := time.Now().Unix()
	if _, err := j.db.Exec("INSERT INTO chat_holds VALUES('100@s.whatsapp.net',1,'200@s.whatsapp.net','unproven_mutation_chat_hold')"); err != nil {
		t.Fatal(err)
	}
	j.ingest(voice("held", now-5, 5))
	drain(t, j, &recognizer{text: "x"})
	if count(t, j, "SELECT count(*) FROM alerts WHERE kind='post_held' AND reason='unproven_mutation_chat_hold'") != 1 {
		t.Fatal("held transcript not logged")
	}
	j.db.Exec("DELETE FROM chat_holds")
	j.ingest(voice("silent", now-5, 5))
	drain(t, j, &recognizer{text: "  "})
	if count(t, j, "SELECT count(*) FROM alerts WHERE kind='unsupported' AND source='silent'") != 1 {
		t.Fatal("unsupported not logged")
	}
	// An unsupported audio from history stays silent.
	m := audio("hist", false, now-5)
	m.History, m.Unsupported = true, "view_once"
	j.ingest(m)
	if count(t, j, "SELECT count(*) FROM alerts WHERE source='hist'") != 0 {
		t.Fatal("history alerted")
	}
}

// The transcript quotes the retained voice note itself, so WhatsApp renders the
// audio bubble and a tap opens the source; without a retained copy the stanza
// and participant still point at the exact message.
func TestReplyQuotesTheSourceAudio(t *testing.T) {
	m := voice("src", 1, 7)
	ctx := replyContext(m)
	if ctx.GetStanzaID() != "src" || ctx.GetParticipant() != m.Sender || ctx.GetQuotedMessage().GetAudioMessage().GetSeconds() != 7 {
		t.Fatal(ctx)
	}
	m.Raw = nil
	ctx = replyContext(m)
	if ctx.GetStanzaID() != "src" || ctx.GetQuotedMessage().GetAudioMessage() != nil || ctx.GetQuotedMessage().GetConversation() == "" {
		t.Fatal(ctx)
	}
	var round waE2E.Message
	b, _ := proto.Marshal(&waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{ContextInfo: replyContext(voice("x", 1, 3))}})
	if proto.Unmarshal(b, &round) != nil || round.GetExtendedTextMessage().GetContextInfo().GetQuotedMessage().GetAudioMessage() == nil {
		t.Fatal("quote does not survive the wire")
	}
}

// Upgrading a journal expires the old backlog silently: no repost, no alert flood.
func TestFreshnessUpgradeExpiresBacklogSilently(t *testing.T) {
	withFresh(t, 300)
	dir := t.TempDir()
	j, err := openJournal(dir)
	if err != nil {
		t.Fatal(err)
	}
	j.save(Config{Account: "100@s.whatsapp.net", Generation: 1, Language: "en", Mode: "transcribe", AllChats: true, Requested: true, Activated: 100, TranscriptPosting: true})
	now := time.Now().Unix()
	j.ingest(voice("old", now-3600, 5))
	j.db.Exec("INSERT INTO outbox(account,generation,chat,source,part,body,send_id,state) VALUES('100@s.whatsapp.net',1,'200@s.whatsapp.net','old',0,'b','s1','ready')")
	// Simulate a pre-freshness journal.
	for _, q := range []string{"ALTER TABLE outbox DROP COLUMN created", "DROP TABLE alerts"} {
		if _, err = j.db.Exec(q); err != nil {
			t.Fatal(q, err)
		}
	}
	j.Close()
	j, err = openJournal(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer j.Close()
	if s, _ := audioState(t, j, "old"); s != "expired" {
		t.Fatal(s)
	}
	if count(t, j, "SELECT count(*) FROM outbox WHERE state='expired'") != 1 || count(t, j, "SELECT count(*) FROM alerts") != 0 {
		t.Fatal("upgrade not silent")
	}
}

func TestAlertFormatting(t *testing.T) {
	items := []alertItem{{chat: "123@g.us", title: "Família", kind: "post_held", reason: "unproven_mutation_chat_hold", sent: 0}}
	for i := 0; i < 14; i++ {
		items = append(items, alertItem{chat: "5511@s.whatsapp.net", kind: "audio_expired", reason: "stale_over_5m"})
	}
	s := formatAlerts(items)
	if !strings.HasPrefix(s, "🛠️ _Copiloto · log_") || !strings.Contains(s, "grupo Família") || !strings.Contains(s, "contato 5511") || !strings.Contains(s, "… +3") {
		t.Fatal(s)
	}
	if alertChat(Config{Account: "100@s.whatsapp.net"}) != "100@s.whatsapp.net" {
		t.Fatal("own chat default")
	}
	t.Setenv("WA_WHATSAPP_ALERT_CHAT", "off")
	if alertChat(Config{Account: "100@s.whatsapp.net"}) != "" {
		t.Fatal("off")
	}
}

func TestOperatorReplyToAudioQuotesTheVoiceNote(t *testing.T) {
	i := operatorIntent{Body: "teste", Reply: "src"}
	m := operatorEnvelope(i, "200@s.whatsapp.net", "")
	quoteAudio(m, voice("src", 1, 9).Raw)
	if m.GetExtendedTextMessage().GetContextInfo().GetQuotedMessage().GetAudioMessage().GetSeconds() != 9 || m.GetExtendedTextMessage().GetContextInfo().GetStanzaID() != "src" {
		t.Fatal(m)
	}
	plain := operatorEnvelope(i, "200@s.whatsapp.net", "Olá")
	quoteAudio(plain, nil)
	if plain.GetExtendedTextMessage().GetContextInfo().GetQuotedMessage().GetConversation() != "Olá" {
		t.Fatal(plain)
	}
}

// An operator reply may name a retained voice note; an unretained audio still refuses.
func TestOperatorMayReplyToARetainedVoiceNote(t *testing.T) {
	j, r, f := operatorFixture(t)
	activate(t, j)
	if err := j.ingest(voice("voice-src", 101, 4)); err != nil {
		t.Fatal(err)
	}
	r.Reply = "voice-src"
	if i := preparedOperator(t, j, r, f); i.Reply != "voice-src" {
		t.Fatal(i)
	}
	m := audio("bare-audio", false, 102)
	m.Raw = nil
	j.ingest(m)
	r.Reply = "bare-audio"
	canonical, route, _ := f.ResolveOperator(context.Background(), r.Chat)
	if _, err := j.prepareOperator(r, canonical, route, f.NewID); err == nil {
		t.Fatal("unretained audio accepted as a reply source")
	}
}

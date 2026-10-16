package main

import (
	"context"
	"errors"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestGapFenceWriteFailureIsFatalNotPretendedDurable(t *testing.T) {
	j := fixture(t)
	j.gapWrite = func(string, []byte) error { return errors.New("private injected storage failure") }
	if j.failPersistence() {
		t.Fatal("failure reported success")
	}
	select {
	case err := <-j.fatal:
		if !errors.Is(err, errGapMarker) {
			t.Fatal(err)
		}
	default:
		t.Fatal("unpersistable gap was not fatal")
	}
	state := j.freshness()
	if state["gap_marker_durable"] != false || state["persistence_gap"] != true || state["connection"] != "degraded_gap_marker_unwritable" {
		t.Fatal(state)
	}
}
func TestActivationRefusesPersistedGapWithoutPairingOrReset(t *testing.T) {
	dir := t.TempDir()
	j, err := openJournal(dir)
	if err != nil {
		t.Fatal(err)
	}
	j.save(Config{Account: "100@s.whatsapp.net", Generation: 1, Language: "pt", Mode: "transcribe", AllChats: true})
	j.failPersistence()
	j.Close()
	old := os.Args
	defer func() { os.Args = old }()
	os.Args = []string{"wa-whatsapp", "activate", "--state", dir, "--approve-transcript-posting"}
	if err = run(); err == nil || !strings.Contains(err.Error(), "gap_requires_reconciliation") {
		t.Fatal("gap activation allowed", err)
	}
	if _, err = os.Stat(filepath.Join(dir, "persistence-gap.json")); err != nil {
		t.Fatal("gap reset by refused action")
	}
}
func TestCallbackPanicCannotBecomeSDKSuccess(t *testing.T) {
	j := fixture(t)
	a := fixtureAdapter(t, j)
	database := j.db
	j.db = nil
	success := a.event(eventAudio("panic"))
	j.db = database
	if success || !j.hasGap() {
		t.Fatal("callback panic became successful processing")
	}
}
func TestOwnerDeleteForMeAndClearFenceFutureSources(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	a := fixtureAdapter(t, j)
	chat := types.NewJID("200", types.DefaultUserServer)
	if !a.event(&events.DeleteForMe{ChatJID: chat, MessageID: "deleted", FromFullSync: true}) {
		t.Fatal("owner delete persistence failed")
	}
	if err := j.ingest(audio("deleted", false, 110)); err != nil {
		t.Fatal(err)
	}
	if count(t, j, "SELECT count(*) FROM audio WHERE state='blocked_source'") != 1 {
		t.Fatal("owner delete before source did not fence later history")
	}
	if !a.event(&events.ClearChat{JID: chat}) {
		t.Fatal("owner clear persistence failed")
	}
	c, _ := j.Config()
	page, err := j.readPage(c, readRequest{Chat: chat.String(), Limit: 10}, "list_chats")
	if err != nil {
		t.Fatal(err)
	}
	rows := page["conversations"].([]map[string]any)
	if len(rows) != 1 || rows[0]["posting_hold_reason"] != "owner_chat_clear_hold" {
		t.Fatal("chat hold not observable", page)
	}
	if !a.client.EmitAppStateEventsOnFullSync {
		t.Fatal("full-sync source removals not observed")
	}
}
func TestBlockedMediaDownloadDoesNotHoldJournalIngestion(t *testing.T) {
	j := fixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		_, err := boundedMedia(ctx, j.dir, &waE2E.AudioMessage{FileLength: proto.Uint64(2)}, func(ctx context.Context, _ whatsmeow.DownloadableMessage, _ whatsmeow.File) error {
			close(started)
			<-ctx.Done()
			return ctx.Err()
		}, time.Second)
		done <- err
	}()
	<-started
	if err := j.ingest(audio("independent", true, 110)); err != nil {
		t.Fatal(err)
	}
	if count(t, j, "SELECT count(*) FROM messages") != 1 {
		t.Fatal("ingestion stalled")
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	entries, _ := filepath.Glob(filepath.Join(j.dir, "media-private-*"))
	if len(entries) != 0 {
		t.Fatal("private media not cleaned")
	}
}

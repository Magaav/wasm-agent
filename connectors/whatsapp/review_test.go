package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"go.mau.fi/whatsmeow/util/cbcutil"
	"google.golang.org/protobuf/proto"
)

func wideFixture(t *testing.T) *Journal {
	j := fixture(t)
	c, _ := j.Config()
	c.AllChats = true
	c.Chats = nil
	if err := j.save(c); err != nil {
		t.Fatal(err)
	}
	return j
}
func TestExplicitAccountWideNewChatsGlobalPagesAndNarrowIsolation(t *testing.T) {
	j := wideFixture(t)
	activate(t, j)
	for i, chat := range []string{"200@s.whatsapp.net", "300@s.whatsapp.net", "400@g.us"} {
		m := audio(string(rune('a'+i)), i == 1, 110)
		m.Chat = chat
		if err := j.ingest(m); err != nil {
			t.Fatal(err)
		}
	}
	old := audio("history", false, 99)
	old.Chat = "500@lid"
	old.History = true
	j.ingest(old)
	bad := audio("status", false, 110)
	bad.Chat = "status@broadcast"
	j.ingest(bad)
	c, _ := j.Config()
	req := readRequest{Account: c.Account, Generation: 1, AccountWide: true, Limit: 2}
	page, err := j.readPage(c, req, "read_snapshot")
	if err != nil {
		t.Fatal(err)
	}
	messages := page["messages"].([]Message)
	if len(messages) != 2 || page["truncated"] != true || page["excluded_scope_count"] != 1 {
		t.Fatal(page)
	}
	req.Before = page["next_before"].(int64)
	older, err := j.readPage(c, req, "read_snapshot")
	if err != nil || len(older["messages"].([]Message)) != 2 {
		t.Fatal(older, err)
	}
	if count(t, j, "SELECT count(*) FROM messages") != 4 || count(t, j, "SELECT count(*) FROM audio WHERE state='pending'") != 3 || count(t, j, "SELECT count(*) FROM audio WHERE state='journal_only'") != 1 {
		t.Fatal("new chats or first-history policy lost")
	}
	narrow, err := j.readPage(c, readRequest{Conversations: []string{"200@s.whatsapp.net"}, Limit: 2}, "read_snapshot")
	if err != nil || len(narrow["messages"].([]Message)) != 1 {
		t.Fatal(narrow, err)
	}
	list, err := j.readPage(c, readRequest{AccountWide: true, Limit: 10}, "list_chats")
	if err != nil || len(list["conversations"].([]map[string]any)) != 4 {
		t.Fatal(list, err)
	}
	selected := fixture(t)
	sc, _ := selected.Config()
	if _, err := selected.readPage(sc, readRequest{AccountWide: true}, "read_snapshot"); err == nil {
		t.Fatal("old config widened")
	}
	if _, _, err := j.readScope(c, readRequest{}, ""); err == nil {
		t.Fatal("operator-wide approval inferred from missing scope")
	}
	if _, err := j.scope("foreign", 1, ""); err == nil {
		t.Fatal("foreign account")
	}
	if _, err := j.scope(c.Account, 2, ""); err == nil {
		t.Fatal("stale generation")
	}
}
func fixtureAdapter(t *testing.T, j *Journal) *Adapter {
	t.Helper()
	a, err := newAdapter(context.Background(), j)
	if err != nil {
		t.Fatal(err)
	}
	id := types.NewJID("100", types.DefaultUserServer)
	a.client.Store.ID = &id
	t.Cleanup(a.Close)
	return a
}
func eventAudio(id string) *events.Message {
	return &events.Message{Info: types.MessageInfo{MessageSource: types.MessageSource{Chat: types.NewJID("200", types.DefaultUserServer), Sender: types.NewJID("200", types.DefaultUserServer)}, ID: id, Timestamp: time.Unix(110, 0)}, Message: &waE2E.Message{AudioMessage: &waE2E.AudioMessage{Mimetype: proto.String("audio/ogg"), FileLength: proto.Uint64(3)}}}
}
func TestSDKSuccessContractFailureRetryAndStickyGap(t *testing.T) {
	j := fixture(t)
	a := fixtureAdapter(t, j)
	activate(t, j)
	j.db.Exec("INSERT INTO outbox(account,generation,chat,source,part,body,send_id,state) VALUES('100@s.whatsapp.net',1,'200@s.whatsapp.net','prior-unknown',0,'fixture','unknown-id','unknown')")
	j.db.Exec("CREATE TRIGGER refuse_message BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT,'private injected persistence failure'); END")
	var callback whatsmeow.EventHandlerWithSuccessStatus = a.event
	if callback(eventAudio("failed")) {
		t.Fatal("failed persistence reported successful")
	}
	// Exact old AddEventHandler wrapper behavior: ignores the callback's result.
	oldWrapper := func(evt any) bool { a.event(evt); return true }
	if !oldWrapper(eventAudio("failed")) || count(t, j, "SELECT count(*) FROM messages") != 0 {
		t.Fatal("old-wrapper causal control")
	}
	j.db.Exec("DROP TRIGGER refuse_message")
	if !callback(eventAudio("failed")) || !callback(eventAudio("failed")) {
		t.Fatal("retry failed")
	}
	if count(t, j, "SELECT count(*) FROM messages") != 1 || count(t, j, "SELECT count(*) FROM audio") != 1 {
		t.Fatal("retry duplicated journal/tasks")
	}
	callback(&events.Connected{})
	callback(&events.OfflineSyncCompleted{})
	status, _ := j.status()
	if status["connection"] != "degraded_persistence_gap" || !j.hasGap() {
		t.Fatal("sync erased gap", status)
	}
	if _, err := os.Stat(filepath.Join(j.dir, "persistence-gap.json")); err != nil {
		t.Fatal("gap not durable", err)
	}
	if !callback(eventAudio("unrelated")) || count(t, j, "SELECT count(*) FROM messages") != 2 {
		t.Fatal("safe ingestion blocked by unrelated failed item")
	}
	if count(t, j, "SELECT count(*) FROM outbox WHERE state='unknown'") != 1 {
		t.Fatal("unrelated unknown relabelled")
	}
	directory := j.dir
	j.Close()
	restarted, err := openJournal(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.Close()
	if !restarted.hasGap() {
		t.Fatal("restart erased unreconciled gap")
	}
	if !a.client.ManualHistorySyncDownload || !a.client.DisableManualHistorySyncReceipt || !a.client.EnableDecryptedEventBuffer {
		t.Fatal("SDK history/buffer policy missing")
	}
}
func TestHistoryPartialFailureBatchReplayIsIdempotent(t *testing.T) {
	j := fixture(t)
	a := fixtureAdapter(t, j)
	blob := &waHistorySync.HistorySync{Conversations: []*waHistorySync.Conversation{{ID: proto.String("200@s.whatsapp.net")}}}
	for _, id := range []string{"first", "second"} {
		blob.Conversations[0].Messages = append(blob.Conversations[0].Messages, &waHistorySync.HistorySyncMsg{Message: &waWeb.WebMessageInfo{Key: &waCommon.MessageKey{ID: proto.String(id), RemoteJID: proto.String("200@s.whatsapp.net")}, MessageTimestamp: proto.Uint64(99), Message: &waE2E.Message{Conversation: proto.String("private fixture")}}})
	}
	j.db.Exec("CREATE TRIGGER refuse_second BEFORE INSERT ON messages WHEN NEW.id='second' BEGIN SELECT RAISE(ABORT,'private batch failure'); END")
	if a.event(&events.HistorySync{Data: blob}) || count(t, j, "SELECT count(*) FROM messages") != 1 {
		t.Fatal("partial history reported successful")
	}
	j.db.Exec("DROP TRIGGER refuse_second")
	if !a.event(&events.HistorySync{Data: blob}) || !a.event(&events.HistorySync{Data: blob}) || count(t, j, "SELECT count(*) FROM messages") != 2 {
		t.Fatal("history retry duplicated/lost")
	}
	if !j.hasGap() {
		t.Fatal("unsupported recovery guarantee cleared gap")
	}
}
func TestMediaBoundOverflowOverheadDeadlineAndCleanup(t *testing.T) {
	dir := t.TempDir()
	msg := &waE2E.AudioMessage{FileLength: proto.Uint64(2)}
	writer := func(_ context.Context, _ whatsmeow.DownloadableMessage, f whatsmeow.File) error {
		_, err := f.Write([]byte("abc"))
		return err
	}
	if _, err := boundedMedia(context.Background(), dir, msg, writer, time.Second); err == nil {
		t.Fatal("declared/actual mismatch accepted")
	}
	overflow := func(_ context.Context, _ whatsmeow.DownloadableMessage, f whatsmeow.File) error {
		_, err := io.Copy(f, io.LimitReader(zeroReader{}, maxEncryptedAudioBytes+1))
		return err
	}
	if _, err := boundedMedia(context.Background(), dir, msg, overflow, time.Second); err == nil {
		t.Fatal("overflow accepted")
	}
	integrity := func(_ context.Context, _ whatsmeow.DownloadableMessage, f whatsmeow.File) error {
		f.Write([]byte("fixture"))
		return whatsmeow.ErrInvalidMediaSHA256
	}
	if data, err := boundedMedia(context.Background(), dir, msg, integrity, time.Second); data != nil || !errors.Is(err, whatsmeow.ErrInvalidMediaSHA256) {
		t.Fatal("upstream integrity failure was swallowed")
	}
	timeout := func(ctx context.Context, _ whatsmeow.DownloadableMessage, _ whatsmeow.File) error {
		<-ctx.Done()
		return ctx.Err()
	}
	if _, err := boundedMedia(context.Background(), dir, msg, timeout, time.Millisecond); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("download deadline missing", err)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Fatal("private media left behind")
	}
	// Real upstream CBC File API works through the bounded seek/write/truncate wrapper.
	key, iv := bytes.Repeat([]byte{1}, 32), bytes.Repeat([]byte{2}, 16)
	plain := bytes.Repeat([]byte("x"), 32)
	encrypted, err := cbcutil.Encrypt(key, iv, plain)
	if err != nil {
		t.Fatal(err)
	}
	file, err := os.CreateTemp(dir, "cbc")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	b := &boundedFile{f: file, max: maxEncryptedAudioBytes}
	b.Write(encrypted)
	b.Seek(0, io.SeekStart)
	if err = cbcutil.DecryptFile(key, iv, b); err != nil {
		t.Fatal(err)
	}
	b.Seek(0, io.SeekStart)
	decoded, _ := io.ReadAll(b)
	if !bytes.Equal(decoded, plain) {
		t.Fatal("CBC File compatibility broken")
	}
	if maxEncryptedAudioBytes-maxAudioBytes != 26 {
		t.Fatal("encrypted overhead not bounded")
	}
}

type zeroReader struct{}

func (zeroReader) Read(p []byte) (int, error) { clear(p); return len(p), nil }
func TestActualMediaHTTPBodyLimitAndTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/slow" {
			select {
			case <-r.Context().Done():
			case <-time.After(time.Second):
			}
			return
		}
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		io.Copy(w, io.LimitReader(zeroReader{}, 1025))
	}))
	defer server.Close()
	client := mediaHTTPClient(100*time.Millisecond, 1024)
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	_, err = io.ReadAll(response.Body)
	response.Body.Close()
	if err == nil {
		t.Fatal("chunked actual overflow not stopped")
	}
	if _, err = client.Get(server.URL + "/slow"); err == nil {
		t.Fatal("actual HTTP timeout not enforced")
	}
}

type refusedFirst struct{ fakeTransport }

func (r *refusedFirst) Ready(_ Config, m Message) error {
	if m.ID == "refused" {
		return errors.New("private refusal")
	}
	return nil
}
func TestRefusedSourceFairnessUnknownAndScopedPostingDiagnosis(t *testing.T) {
	j := wideFixture(t)
	activate(t, j)
	a := audio("refused", false, 110)
	b := audio("healthy", true, 120)
	b.Chat = "300@s.whatsapp.net"
	j.ingest(a)
	j.ingest(b)
	transport := &refusedFirst{}
	r := &recognizer{text: "fixture"}
	j.processAudio(context.Background(), transport, r)
	j.processAudio(context.Background(), transport, r)
	j.post(context.Background(), transport)
	j.post(context.Background(), transport)
	if transport.sent != 1 || count(t, j, "SELECT count(*) FROM outbox WHERE state='ready'") != 1 || count(t, j, "SELECT count(*) FROM post_retry") != 1 {
		t.Fatal("refused head stalled other chat")
	}
	c, _ := j.Config()
	page, err := j.readPage(c, readRequest{Conversations: []string{"200@s.whatsapp.net"}, Limit: 1}, "posting_status")
	if err != nil || len(page["posts"].([]map[string]any)) != 1 {
		t.Fatal(page, err)
	}
	post := page["posts"].([]map[string]any)[0]
	if post["reason"] != "definite_pre_dispatch_refusal" || post["next_attempt"].(int64) <= time.Now().Unix() {
		t.Fatal("not-submitted reason/retry missing", post)
	}
	j.db.Exec("UPDATE outbox SET state='unknown' WHERE source='healthy'")
	j.post(context.Background(), transport)
	if transport.sent != 1 || count(t, j, "SELECT count(*) FROM outbox WHERE state='unknown'") != 1 {
		t.Fatal("unknown replayed/relabelled")
	}
}
func TestUnexpectedAPIStopIsNonzeroButRequestedShutdownNormal(t *testing.T) {
	for _, normal := range []bool{false, true} {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		server := &http.Server{Handler: http.NotFoundHandler()}
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		if normal {
			cancel()
		}
		listener.Close()
		go serveAPI(server, listener, ctx, cancel, done)
		err = <-done
		if (err == nil) != normal {
			t.Fatal("unexpected Serve failure became successful exit", normal, err)
		}
		cancel()
	}
}
func TestVerifiedRevokeEditBlocksQueuedAndInFlightComputeWithoutReset(t *testing.T) {
	for _, mutation := range []string{"revoke", "edit"} {
		t.Run(mutation, func(t *testing.T) {
			j := fixture(t)
			activate(t, j)
			m := audio("source", false, 110)
			j.ingest(m)
			f := &fakeTransport{}
			j.processAudio(context.Background(), f, &recognizer{text: strings.Repeat("a", 3000)})
			j.db.Exec("UPDATE outbox SET state='unknown' WHERE part=0")
			change := Message{ID: "mutation", Target: "source", Chat: m.Chat, Sender: m.Sender, Mutation: mutation, MutationScope: true}
			if err := j.ingest(change); err != nil {
				t.Fatal(err)
			}
			j.post(context.Background(), f)
			if f.sent != 0 || count(t, j, "SELECT count(*) FROM outbox WHERE state='unknown'") != 1 || count(t, j, "SELECT count(*) FROM outbox WHERE state='blocked'") != 1 {
				t.Fatal("source mutation replayed or reset evidence")
			}
		})
	}
	j := fixture(t)
	activate(t, j)
	j.ingest(audio("inflight", false, 110))
	f := &fakeTransport{}
	r := &mutationRecognizer{j: j}
	if err := j.processAudio(context.Background(), f, r); err != nil {
		t.Fatal(err)
	}
	if count(t, j, "SELECT count(*) FROM outbox") != 0 || count(t, j, "SELECT count(*) FROM audio WHERE state='blocked_source'") != 1 {
		t.Fatal("in-flight compute published invalid source")
	}
	unknown := Message{ID: "unmapped", Target: "absent", Chat: "200@s.whatsapp.net", Sender: "foreign", Mutation: "revoke", MutationScope: false}
	j.ingest(unknown)
	if count(t, j, "SELECT count(*) FROM chat_holds") != 1 {
		t.Fatal("unprovable mutation did not hold chat")
	}
}

type mutationRecognizer struct{ j *Journal }

func (r *mutationRecognizer) Transcribe(context.Context, string, string) (string, error) {
	return "must not post", r.j.ingest(Message{Chat: "200@s.whatsapp.net", Target: "inflight", Sender: "200@s.whatsapp.net", Mutation: "edit", MutationScope: true})
}
func TestPinnedMutationMappingExactIDsAndNoTitleGuess(t *testing.T) {
	e := eventAudio("event-id")
	e.Message = &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{Type: waE2E.ProtocolMessage_REVOKE.Enum(), Key: &waCommon.MessageKey{ID: proto.String("source-id"), RemoteJID: proto.String("200@s.whatsapp.net")}}}
	m := mapMessage(e, false)
	if m.Target != "source-id" || m.Mutation != "revoke" || !m.MutationScope {
		t.Fatal(m)
	}
	e.Message.ProtocolMessage.Key.RemoteJID = proto.String("foreign@g.us")
	if mapMessage(e, false).MutationScope {
		t.Fatal("foreign mutation mapped")
	}
}

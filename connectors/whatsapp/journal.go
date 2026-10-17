// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/gofrs/flock"
	_ "modernc.org/sqlite"
)

type Config struct {
	Account         string   `json:"account"`
	Generation      int64    `json:"generation"`
	Language        string   `json:"language"`
	Requested       bool     `json:"requested_on"`
	Activated       int64    `json:"activated_at"`
	Chats           []string `json:"chats"`
	AllChats        bool     `json:"all_chats"`
	Mode            string   `json:"mode"`
	PairingRequired bool     `json:"pairing_required"`
}
type Message struct {
	ID               string `json:"id"`
	Chat             string `json:"conversation_id"`
	Sender           string `json:"sender"`
	Body             string `json:"body"`
	Sent             int64  `json:"sent_at"`
	Own              bool   `json:"from_me"`
	History          bool   `json:"history"`
	Audio            bool   `json:"audio"`
	Unsupported      string `json:"unsupported,omitempty"`
	Raw              []byte `json:"-"`
	Transcript       string `json:"transcript,omitempty"`
	AudioState       string `json:"audio_state,omitempty"`
	AudioReason      string `json:"audio_reason,omitempty"`
	Cursor           int64  `json:"cursor"`
	Observed         int64  `json:"observed_at"`
	Mutation         string `json:"-"`
	Target           string `json:"-"`
	MutationScope    bool   `json:"-"`
	OwnerMutation    bool   `json:"-"`
	OriginAccount    string `json:"-"`
	OriginGeneration int64  `json:"-"`
}
type Journal struct {
	db             *sql.DB
	lock           *flock.Flock
	accountLock    *flock.Flock
	mu             sync.Mutex
	state          string
	verified       bool
	authenticated  bool
	adapterLive    bool
	pairingBlocked bool
	identityMu     sync.Mutex
	dir            string
	effectMu       sync.Mutex
	gap            bool
	gapDurable     bool
	fatal          chan error
	gapWrite       func(string, []byte) error
	sourceState    string
}

func openJournal(dir string) (*Journal, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(dir)
	if err != nil || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("symlink_state_refused")
	}
	for _, name := range []string{"owner.lock", "journal.db", "journal.db-wal", "journal.db-shm", "device-keys.db", "device-keys.db-wal", "device-keys.db-shm", "api.token", "audio-work", "persistence-gap.json"} {
		if info, e := os.Lstat(filepath.Join(dir, name)); e == nil && info.Mode()&os.ModeSymlink != 0 {
			return nil, errors.New("symlink_state_file_refused")
		}
	}
	if err := os.Chmod(dir, 0700); err != nil {
		return nil, err
	}
	l := flock.New(filepath.Join(dir, "owner.lock"))
	ok, err := l.TryLock()
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errors.New("account_owner_busy")
	}
	db, err := sql.Open("sqlite", filepath.Join(dir, "journal.db"))
	if err != nil {
		l.Unlock()
		return nil, err
	}
	db.SetMaxOpenConns(1)
	j := &Journal{db: db, lock: l, dir: dir, state: "disconnected", fatal: make(chan error, 1), gapWrite: writeNewSecret}
	_, err = db.Exec(`PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
 CREATE TABLE IF NOT EXISTS config(id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS messages(account TEXT NOT NULL,generation INTEGER NOT NULL,chat TEXT NOT NULL,id TEXT NOT NULL,sender TEXT NOT NULL,body TEXT NOT NULL,sent INTEGER NOT NULL,observed INTEGER NOT NULL,own INTEGER NOT NULL,history INTEGER NOT NULL,audio INTEGER NOT NULL,unsupported TEXT NOT NULL,raw BLOB,PRIMARY KEY(account,generation,chat,id));
 CREATE TABLE IF NOT EXISTS audio(account TEXT NOT NULL,generation INTEGER NOT NULL,chat TEXT NOT NULL,id TEXT NOT NULL,state TEXT NOT NULL,reason TEXT NOT NULL DEFAULT '',transcript TEXT NOT NULL DEFAULT '',language TEXT NOT NULL,next_attempt INTEGER NOT NULL DEFAULT 0,attempts INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(account,generation,chat,id));
 CREATE TABLE IF NOT EXISTS outbox(account TEXT NOT NULL,generation INTEGER NOT NULL,chat TEXT NOT NULL,source TEXT NOT NULL,part INTEGER NOT NULL,body TEXT NOT NULL,send_id TEXT NOT NULL,state TEXT NOT NULL,ack TEXT NOT NULL DEFAULT '',PRIMARY KEY(account,generation,chat,source,part),UNIQUE(account,generation,chat,send_id));
 CREATE TABLE IF NOT EXISTS lifecycle(slot TEXT PRIMARY KEY,value TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,at INTEGER NOT NULL,detail TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS chats(account TEXT,generation INTEGER,chat TEXT,PRIMARY KEY(account,generation,chat));
 INSERT OR IGNORE INTO chats(account,generation,chat) SELECT account,generation,chat FROM messages;
 CREATE TABLE IF NOT EXISTS excluded(account TEXT,generation INTEGER,chat TEXT,id TEXT,reason TEXT,PRIMARY KEY(account,generation,chat,id));
 CREATE TABLE IF NOT EXISTS source_blocks(account TEXT,generation INTEGER,chat TEXT,id TEXT,reason TEXT,PRIMARY KEY(account,generation,chat,id));
 CREATE TABLE IF NOT EXISTS chat_holds(account TEXT,generation INTEGER,chat TEXT,reason TEXT,PRIMARY KEY(account,generation,chat));
 CREATE TABLE IF NOT EXISTS post_retry(account TEXT,generation INTEGER,chat TEXT,source TEXT,part INTEGER,next_attempt INTEGER,reason TEXT,PRIMARY KEY(account,generation,chat,source,part));
 UPDATE outbox SET state='unknown' WHERE state='reserved';`)
	if err != nil {
		j.Close()
		return nil, err
	}
	if err = installDirectory(db); err != nil {
		j.Close()
		return nil, err
	}
	if err = installReadVersions(db); err != nil {
		j.Close()
		return nil, err
	}
	os.Chmod(filepath.Join(dir, "journal.db"), 0600)
	if _, e := os.Stat(filepath.Join(dir, "persistence-gap.json")); e == nil {
		j.gap = true
		j.gapDurable = true
		j.state = "degraded_persistence_gap"
	}
	return j, nil
}
func (j *Journal) Close() {
	j.db.Close()
	j.lock.Unlock()
	if j.accountLock != nil {
		j.accountLock.Unlock()
	}
}
func (j *Journal) fence(root, account string) error {
	if err := os.MkdirAll(root, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(root)
	if err != nil || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("owner_root_symlink_refused")
	}
	os.Chmod(root, 0700)
	key := fmt.Sprintf("%x", sha256.Sum256([]byte(account)))
	l := flock.New(filepath.Join(root, key+".lock"))
	ok, err := l.TryLock()
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("account_owner_busy")
	}
	j.accountLock = l
	return nil
}
func validChat(s string) bool {
	p := strings.Split(s, "@")
	if len(p) != 2 {
		return false
	}
	for _, r := range p[0] {
		if !strings.ContainsRune("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ:._-", r) {
			return false
		}
	}
	return len(s) <= 256 && len(p) == 2 && p[0] != "" && !strings.ContainsAny(p[0], " /\\\x00\r\n") && (p[1] == "s.whatsapp.net" || p[1] == "lid" || p[1] == "g.us")
}
func validConfig(c Config) error {
	if c.Account == "" || strings.ContainsAny(c.Account, "\x00\r\n") || c.Generation < 1 {
		return errors.New("invalid_account_generation")
	}
	if c.Language != "en" && c.Language != "pt" && c.Language != "auto" {
		return errors.New("language_must_be_en_pt_auto")
	}
	if c.Mode != "transcribe" {
		return errors.New("cross_language_translation_unsupported")
	}
	if !c.AllChats && len(c.Chats) == 0 {
		return errors.New("explicit_chat_scope_required")
	}
	for _, chat := range c.Chats {
		if !validChat(chat) {
			return errors.New("invalid_chat")
		}
	}
	return nil
}
func (j *Journal) Config() (Config, error) {
	var c Config
	var s string
	err := j.db.QueryRow("SELECT value FROM config WHERE id=1").Scan(&s)
	if err != nil {
		return c, err
	}
	err = json.Unmarshal([]byte(s), &c)
	return c, err
}
func (j *Journal) save(c Config) error {
	if err := validConfig(c); err != nil {
		return err
	}
	b, _ := json.Marshal(c)
	_, err := j.db.Exec("INSERT INTO config VALUES(1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value", string(b))
	return err
}
func contains(ss []string, s string) bool {
	for _, v := range ss {
		if v == s {
			return true
		}
	}
	return false
}
func (j *Journal) scope(account string, generation int64, chat string) (Config, error) {
	c, err := j.Config()
	if err != nil {
		return c, err
	}
	if c.Account != account || c.Generation != generation {
		return c, errors.New("account_generation_mismatch")
	}
	if chat != "" && (!validChat(chat) || (!c.AllChats && !contains(c.Chats, chat))) {
		return c, errors.New("chat_not_authorized")
	}
	return c, nil
}
func (j *Journal) event(kind, detail string) error {
	_, err := j.db.Exec("INSERT INTO events(kind,at,detail) VALUES(?,?,?)", kind, time.Now().Unix(), detail)
	return err
}
func (j *Journal) setState(s string) {
	j.mu.Lock()
	j.sourceState = s
	j.state = s
	if j.gap {
		j.state = "degraded_persistence_gap"
	}
	if s == "needs_pairing" || s == "degraded_account_mismatch" {
		j.verified = false
		j.authenticated = false
	}
	j.mu.Unlock()
}
func (j *Journal) status() (map[string]any, error) {
	c, err := j.Config()
	if err != nil {
		return nil, err
	}
	j.mu.Lock()
	s := j.state
	j.mu.Unlock()
	counts := map[string]int{}
	rows, err := j.db.Query("SELECT state,count(*) FROM audio WHERE account=? AND generation=? GROUP BY state", c.Account, c.Generation)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var k string
		var n int
		if err = rows.Scan(&k, &n); err != nil {
			rows.Close()
			return nil, err
		}
		counts[k] = n
	}
	if err = rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()
	var unknown int
	if err = j.db.QueryRow("SELECT count(*) FROM outbox WHERE state='unknown'").Scan(&unknown); err != nil {
		return nil, err
	}
	var lastObserved int64
	if err = j.db.QueryRow("SELECT COALESCE(MAX(observed),0) FROM messages WHERE account=? AND generation=?", c.Account, c.Generation).Scan(&lastObserved); err != nil {
		return nil, err
	}
	var excluded int
	if err = j.db.QueryRow("SELECT count(*) FROM excluded WHERE account=? AND generation=?", c.Account, c.Generation).Scan(&excluded); err != nil {
		return nil, err
	}
	observation, err := j.sessionObservation()
	if err != nil {
		return nil, err
	}
	return map[string]any{"session_observation": observation, "ok": true, "excluded_scope_count": excluded, "source_state": j.freshness(), "snapshot_at": time.Now().Unix(), "last_journal_observed_at": lastObserved, "config": c, "connection": s, "audio": counts, "unknown_sends": unknown, "draft_visibility": "unsupported", "history_coverage": "partial; upstream history and redelivery are not guaranteed", "edit_delete_receipt_coverage": "events retained; no full message-state reconstruction", "translation": "unsupported; original-language recognition only"}, nil
}
func (j *Journal) ingest(m Message) error {
	c, err := j.Config()
	if err != nil {
		return err
	}
	if !validChat(m.Chat) {
		return j.exclude(c, m, "unsupported_chat_scope")
	}
	if !c.AllChats && !contains(c.Chats, m.Chat) {
		return j.exclude(c, m, "unapproved_selected_scope")
	}
	if m.Mutation != "" {
		return j.mutate(c, m)
	}
	if m.ID == "" || len(m.ID) > 256 || !validChat(m.Chat) {
		return errors.New("invalid_message_identity")
	}
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	r, err := tx.Exec(`INSERT OR IGNORE INTO messages VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)`, c.Account, c.Generation, m.Chat, m.ID, m.Sender, m.Body, m.Sent, time.Now().Unix(), m.Own, m.History, m.Audio, m.Unsupported, m.Raw)
	if err != nil {
		return err
	}
	n, _ := r.RowsAffected()
	if _, err = tx.Exec("INSERT OR IGNORE INTO chats(account,generation,chat) VALUES(?,?,?)", c.Account, c.Generation, m.Chat); err != nil {
		return err
	}
	// Echoes confirm only a previously reserved exact ID/recipient/body; never create sends.
	if m.Own {
		_, err = tx.Exec("UPDATE outbox SET state='confirmed',ack='exact own-message echo; delivery receipt unknown' WHERE account=? AND generation=? AND chat=? AND send_id=? AND body=? AND state IN ('unknown','reserved')", c.Account, c.Generation, m.Chat, m.ID, m.Body)
		if err != nil {
			return err
		}
	}
	if n > 0 && m.Audio {
		state, reason := "journal_only", "before_activation"
		if c.Activated > 0 && m.Sent >= c.Activated {
			state, reason = "pending", ""
		}
		if m.Sent <= 0 {
			state, reason = "unsupported", "timestamp_unknown"
		}
		if m.Sent > time.Now().Unix()+300 {
			state, reason = "unsupported", "future_timestamp_untrusted"
		}
		if m.Unsupported != "" {
			state, reason = "unsupported", m.Unsupported
		}
		blocked, e := blockedSource(tx, c, m.Chat, m.ID)
		if e != nil {
			return e
		}
		if blocked {
			state, reason = "blocked_source", "source_mutation_or_chat_hold"
		}
		_, err = tx.Exec("INSERT INTO audio(account,generation,chat,id,state,reason,language) VALUES(?,?,?,?,?,?,?)", c.Account, c.Generation, m.Chat, m.ID, state, reason, c.Language)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

type Transport interface {
	Download(context.Context, Message) ([]byte, error)
	Send(context.Context, string, string, string, Message) (string, error)
	NewID() string
}
type Recognizer interface {
	Transcribe(context.Context, string, string) (string, error)
}
type permanentError string

func (e permanentError) Error() string { return string(e) }
func chunks(s string) []string {
	var out []string
	rs := []rune(s)
	for len(rs) > 0 {
		n := len(rs)
		if n > 2500 {
			n = 2500
		}
		out = append(out, string(rs[:n]))
		rs = rs[n:]
	}
	for i := range out {
		out[i] = fmt.Sprintf("🎙️ _Automated transcript_ (%d/%d)\n%s", i+1, len(out), out[i])
	}
	return out
}
func (j *Journal) processAudio(ctx context.Context, t Transport, r Recognizer) error {
	c, err := j.Config()
	if err != nil {
		return err
	}
	if !c.Requested {
		return nil
	}
	var m Message
	var language string
	err = j.db.QueryRow(`SELECT m.chat,m.id,m.sender,m.body,m.sent,m.own,m.raw,a.language FROM audio a JOIN messages m USING(account,generation,chat,id) WHERE a.account=? AND a.generation=? AND a.state='pending' AND NOT EXISTS(SELECT 1 FROM source_blocks b WHERE b.account=a.account AND b.generation=a.generation AND b.chat=a.chat AND b.id=a.id) AND NOT EXISTS(SELECT 1 FROM chat_holds h WHERE h.account=a.account AND h.generation=a.generation AND h.chat=a.chat) AND a.next_attempt<=? ORDER BY a.attempts,m.observed LIMIT 1`, c.Account, c.Generation, time.Now().Unix()).Scan(&m.Chat, &m.ID, &m.Sender, &m.Body, &m.Sent, &m.Own, &m.Raw, &language)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	b, err := t.Download(ctx, m)
	if err == nil && len(b) > 20*1024*1024 {
		err = permanentError("audio_too_large")
	}
	var text string
	if err == nil {
		path := filepath.Join(j.dir, "audio-work")
		err = os.WriteFile(path, b, 0600)
		if err == nil {
			text, err = r.Transcribe(ctx, path, language)
		}
		os.Remove(path)
	}
	if err == nil && (!utf8.ValidString(text) || len([]rune(text)) > 12000) {
		err = permanentError("transcript_invalid_or_too_long")
	}
	if err == nil && strings.TrimSpace(text) == "" {
		err = permanentError("no_speech")
	}
	if err != nil {
		state := "pending"
		var p permanentError
		if errors.As(err, &p) {
			state = "unsupported"
		}
		_, e := j.db.Exec("UPDATE audio SET state=?,reason=?,attempts=attempts+1,next_attempt=? WHERE account=? AND generation=? AND chat=? AND id=?", state, safeReason(err), time.Now().Add(time.Minute).Unix(), c.Account, c.Generation, m.Chat, m.ID)
		return e
	}
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	blocked, e := blockedSource(tx, c, m.Chat, m.ID)
	if e != nil {
		return e
	}
	if blocked {
		_, e = tx.Exec("UPDATE audio SET state='blocked_source',reason='source_mutation_or_chat_hold' WHERE account=? AND generation=? AND chat=? AND id=?", c.Account, c.Generation, m.Chat, m.ID)
		if e != nil {
			return e
		}
		return tx.Commit()
	}
	for i, body := range chunks(text) {
		_, err = tx.Exec("INSERT OR IGNORE INTO outbox(account,generation,chat,source,part,body,send_id,state) VALUES(?,?,?,?,?,?,?,'ready')", c.Account, c.Generation, m.Chat, m.ID, i, body, t.NewID())
		if err != nil {
			return err
		}
	}
	_, err = tx.Exec("UPDATE audio SET state='transcribed',reason='',transcript=? WHERE account=? AND generation=? AND chat=? AND id=?", text, c.Account, c.Generation, m.Chat, m.ID)
	if err != nil {
		return err
	}
	return tx.Commit()
}
func safeReason(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "media_download_deadline"
	}
	if errors.Is(err, context.Canceled) {
		return "processing_cancelled"
	}
	var p permanentError
	if errors.As(err, &p) {
		return string(p)
	}
	switch err.Error() {
	case "local_worker_not_configured", "local_model_cache_missing", "WA_WHATSAPP_STT_MODELS_required", "faster_whisper_missing", "offline_model_unavailable", "worker_compute_failed", "worker_timeout", "worker_eof", "worker_protocol":
		return err.Error()
	}
	return "retryable_media_or_compute_failure"
} // Never log protocol keys/URLs or recognizer paths.
func (j *Journal) post(ctx context.Context, t Transport) error {
	if j.hasGap() {
		return nil
	}
	c, err := j.Config()
	if err != nil {
		return err
	}
	if !c.Requested {
		return nil
	}
	var source Message
	var part int
	var body, id string
	err = j.db.QueryRow(`SELECT o.chat,o.source,o.part,o.body,o.send_id,m.sender,m.own FROM outbox o JOIN messages m ON m.account=o.account AND m.generation=o.generation AND m.chat=o.chat AND m.id=o.source WHERE o.account=? AND o.generation=? AND o.state='ready' AND NOT EXISTS(SELECT 1 FROM source_blocks b WHERE b.account=o.account AND b.generation=o.generation AND b.chat=o.chat AND b.id=o.source) AND NOT EXISTS(SELECT 1 FROM chat_holds h WHERE h.account=o.account AND h.generation=o.generation AND h.chat=o.chat) AND NOT EXISTS(SELECT 1 FROM post_retry r WHERE r.account=o.account AND r.generation=o.generation AND r.chat=o.chat AND r.source=o.source AND r.part=o.part AND r.next_attempt>unixepoch()) AND NOT EXISTS(SELECT 1 FROM outbox p WHERE p.account=o.account AND p.generation=o.generation AND p.chat=o.chat AND p.source=o.source AND p.part<o.part AND p.state!='confirmed') ORDER BY m.observed,o.rowid,o.part LIMIT 1`, c.Account, c.Generation).Scan(&source.Chat, &source.ID, &part, &body, &id, &source.Sender, &source.Own)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	source.OriginAccount = c.Account
	source.OriginGeneration = c.Generation
	if ready, ok := t.(interface{ Ready(Config, Message) error }); ok {
		if err := ready.Ready(c, source); err != nil {
			return j.deferPost(c, source, part, err, false)
		}
	}
	// Final source/config recheck and durable uncertainty fence. Do not hold the
	// mutation lock through Ready or an external ACK wait.
	admitted, err := j.admitPost(c, source, part)
	if err != nil || !admitted {
		return err
	}
	ack, sendErr := t.Send(ctx, source.Chat, body, id, source)
	if sendErr != nil {
		var proof notSubmittedError
		if errors.As(sendErr, &proof) {
			return j.deferPost(c, source, part, proof.cause, true)
		}
		return nil
	} // Only typed pre-API proof is retryable; generic SDK errors/ack loss remain unknown.
	if ack != id {
		return nil
	}
	_, err = j.db.Exec("UPDATE outbox SET state='confirmed',ack='server accepted exact send id; recipient delivery/read unknown' WHERE account=? AND generation=? AND chat=? AND source=? AND part=?", c.Account, c.Generation, source.Chat, source.ID, part)
	return err
}

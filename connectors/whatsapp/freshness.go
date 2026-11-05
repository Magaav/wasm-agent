// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strings"
	"time"
)

// Freshness and the operator log. See docs/WHATSAPP-TRANSCRIPTION.md
// ("Fresh-only transcripts and the own-chat log").
//
// A transcript is only worth posting while the conversation is still live:
//   - pending audio not picked up within freshSeconds of being sent expires
//     (state 'expired', reason 'stale_over_5m'); it is never transcribed later;
//   - a ready transcript part not dispatched within freshSeconds of being
//     queued expires too (outbox state 'expired'); nothing old is ever reposted.
//
// Every fresh audio that ends without a posted transcript (expired, failed,
// unsupported, fenced, or transcribed into a held chat) queues one alert. The
// alert poster sends them, coalesced, as plain text to this account's own chat
// (the "message yourself" chat), never into the source chat. An alert carries
// the chat title, the send time and the reason: never audio or transcript text.

const (
	alertMinGap   = 60 * time.Second // at most one log message per minute
	alertBatchMax = 12               // items listed per message; the rest are counted
	alertMaxAge   = 6 * 3600         // an alert not deliverable for 6 h is dropped
)

var freshSeconds = int64(envInt("WA_WHATSAPP_FRESH_SECONDS", 300, 60, 86400))

func installFreshness(db *sql.DB) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS alerts(seq INTEGER PRIMARY KEY AUTOINCREMENT,account TEXT NOT NULL,generation INTEGER NOT NULL,chat TEXT NOT NULL,source TEXT NOT NULL,kind TEXT NOT NULL,reason TEXT NOT NULL,sent INTEGER NOT NULL,at INTEGER NOT NULL,state TEXT NOT NULL DEFAULT 'ready',UNIQUE(account,generation,chat,source,kind))`); err != nil {
		return err
	}
	var present int
	if err := db.QueryRow("SELECT count(*) FROM pragma_table_info('outbox') WHERE name='created'").Scan(&present); err != nil {
		return err
	}
	if present != 0 {
		return nil
	}
	if _, err := db.Exec("ALTER TABLE outbox ADD COLUMN created INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	// One-time upgrade: anything queued before freshness existed is old by
	// definition. Expire it silently (no alert flood, no repost of old work).
	now := time.Now().Unix()
	if _, err := db.Exec("UPDATE outbox SET state='expired',ack='stale_at_freshness_upgrade' WHERE state='ready'"); err != nil {
		return err
	}
	_, err := db.Exec("UPDATE audio SET state='expired',reason='stale_at_freshness_upgrade' WHERE state='pending' AND EXISTS(SELECT 1 FROM messages m WHERE m.account=audio.account AND m.generation=audio.generation AND m.chat=audio.chat AND m.id=audio.id AND m.sent<?)", now-freshSeconds)
	return err
}

// queueAlert records one alert for an audio that will not get a posted
// transcript. Only live audio alerts: history, or audio already older than the
// fresh window when it settles at ingest, stays silent.
func queueAlert(tx rowExec, c Config, chat, source, kind, reason string, sent int64) error {
	if alertChat(c) == "" {
		return nil
	}
	_, err := tx.Exec("INSERT OR IGNORE INTO alerts(account,generation,chat,source,kind,reason,sent,at) VALUES(?,?,?,?,?,?,?,?)", c.Account, c.Generation, chat, source, kind, reason, sent, time.Now().Unix())
	return err
}

type rowExec interface {
	Exec(string, ...any) (sql.Result, error)
}

// alertChat is where the log goes: this account's own chat, unless
// WA_WHATSAPP_ALERT_CHAT names another exact JID or "off".
func alertChat(c Config) string {
	switch v := strings.TrimSpace(os.Getenv("WA_WHATSAPP_ALERT_CHAT")); {
	case v == "off":
		return ""
	case v != "" && validChat(v):
		return v
	}
	if validChat(c.Account) {
		return c.Account
	}
	return ""
}

// expireStale moves stale pending audio and stale ready outbox parts to
// 'expired' and queues an alert for each. Audio a lane is decoding right now is
// left alone: once picked up in time, its transcript is still fresh.
func (j *Journal) expireStale(now int64) (int, error) {
	c, err := j.Config()
	if err != nil || !c.Requested {
		return 0, err
	}
	cut := now - freshSeconds
	tx, err := j.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	rows, err := tx.Query("SELECT a.chat,a.id,a.reason,m.sent,m.history FROM audio a JOIN messages m USING(account,generation,chat,id) WHERE a.account=? AND a.generation=? AND a.state='pending' AND m.sent<?", c.Account, c.Generation, cut)
	if err != nil {
		return 0, err
	}
	type stale struct {
		chat, id, reason string
		sent             int64
		history          bool
	}
	var audio []stale
	j.queue.mu.Lock()
	for rows.Next() {
		var s stale
		if err = rows.Scan(&s.chat, &s.id, &s.reason, &s.sent, &s.history); err != nil {
			break
		}
		if j.queue.inflight[s.chat+"\x00"+s.id] {
			continue
		}
		audio = append(audio, s)
	}
	j.queue.mu.Unlock()
	rows.Close()
	if err != nil {
		return 0, err
	}
	for _, s := range audio {
		r, e := tx.Exec("UPDATE audio SET state='expired',reason=? WHERE account=? AND generation=? AND chat=? AND id=? AND state='pending'", expiredReason(s.reason), c.Account, c.Generation, s.chat, s.id)
		if e != nil {
			return 0, e
		}
		if n, _ := r.RowsAffected(); n == 1 && !s.history {
			if e = queueAlert(tx, c, s.chat, s.id, "audio_expired", expiredReason(s.reason), s.sent); e != nil {
				return 0, e
			}
		}
	}
	rows, err = tx.Query("SELECT o.chat,o.source,min(o.part),COALESCE(max(r.reason),''),m.sent FROM outbox o JOIN messages m ON m.account=o.account AND m.generation=o.generation AND m.chat=o.chat AND m.id=o.source LEFT JOIN post_retry r ON r.account=o.account AND r.generation=o.generation AND r.chat=o.chat AND r.source=o.source AND r.part=o.part WHERE o.account=? AND o.generation=? AND o.state='ready' AND o.created<? GROUP BY o.chat,o.source", c.Account, c.Generation, cut)
	if err != nil {
		return 0, err
	}
	var posts []stale
	for rows.Next() {
		var s stale
		var part int
		if err = rows.Scan(&s.chat, &s.id, &part, &s.reason, &s.sent); err != nil {
			break
		}
		posts = append(posts, s)
	}
	rows.Close()
	if err != nil {
		return 0, err
	}
	for _, s := range posts {
		if _, e := tx.Exec("UPDATE outbox SET state='expired',ack='stale_over_5m' WHERE account=? AND generation=? AND chat=? AND source=? AND state='ready'", c.Account, c.Generation, s.chat, s.id); e != nil {
			return 0, e
		}
		reason := "post_not_sent_in_window"
		if s.reason != "" {
			reason += " (" + s.reason + ")"
		}
		if e := queueAlert(tx, c, s.chat, s.id, "post_expired", reason, s.sent); e != nil {
			return 0, e
		}
	}
	if len(audio)+len(posts) == 0 {
		return 0, nil
	}
	if _, err = tx.Exec("INSERT INTO events(kind,at,detail) VALUES('fresh_expired',?,?)", now, fmt.Sprintf("audio=%d posts=%d", len(audio), len(posts))); err != nil {
		return 0, err
	}
	return len(audio) + len(posts), tx.Commit()
}

func expiredReason(prior string) string {
	if prior == "" || prior == "source_hold_transcription_only" {
		return "stale_over_5m"
	}
	return "stale_over_5m (" + prior + ")"
}

// Notifier sends one plain-text log message to an exact chat.
type Notifier interface {
	Notify(ctx context.Context, chat, body string) error
}

// sendAlerts delivers the queued alerts as one coalesced message, at most once
// per alertMinGap. It reports whether it sent.
func (j *Journal) sendAlerts(ctx context.Context, n Notifier, last *time.Time) (bool, error) {
	c, err := j.Config()
	if err != nil || !c.Requested {
		return false, err
	}
	to := alertChat(c)
	if to == "" || time.Since(*last) < alertMinGap {
		return false, nil
	}
	now := time.Now().Unix()
	if _, err = j.db.Exec("UPDATE alerts SET state='dropped' WHERE account=? AND generation=? AND state='ready' AND at<?", c.Account, c.Generation, now-alertMaxAge); err != nil {
		return false, err
	}
	rows, err := j.db.Query("SELECT a.seq,a.chat,a.kind,a.reason,a.sent,COALESCE(NULLIF(h.title,''),'') FROM alerts a LEFT JOIN chats h ON h.account=a.account AND h.generation=a.generation AND h.chat=a.chat WHERE a.account=? AND a.generation=? AND a.state='ready' ORDER BY a.seq LIMIT 200", c.Account, c.Generation)
	if err != nil {
		return false, err
	}
	var items []alertItem
	for rows.Next() {
		var it alertItem
		if err = rows.Scan(&it.seq, &it.chat, &it.kind, &it.reason, &it.sent, &it.title); err != nil {
			break
		}
		items = append(items, it)
	}
	rows.Close()
	if err != nil || len(items) == 0 {
		return false, err
	}
	*last = time.Now()
	if err = n.Notify(ctx, to, formatAlerts(items)); err != nil {
		return false, nil // retried after alertMinGap; a log is not worth more
	}
	for _, it := range items {
		if _, err = j.db.Exec("UPDATE alerts SET state='sent' WHERE seq=?", it.seq); err != nil {
			return true, err
		}
	}
	return true, nil
}

type alertItem struct {
	seq                       int64
	chat, kind, reason, title string
	sent                      int64
}

var alertKinds = map[string]string{
	"audio_expired": "não transcrito em 5 min",
	"post_expired":  "transcrito, mas não enviado em 5 min",
	"post_held":     "transcrito, envio bloqueado (chat em espera)",
	"failed":        "transcrição falhou",
	"unsupported":   "áudio não suportado",
	"blocked":       "bloqueado (revoke/espera)",
}

var saoPaulo = func() *time.Location {
	if l, err := time.LoadLocation("America/Sao_Paulo"); err == nil {
		return l
	}
	return time.FixedZone("BRT", -3*3600)
}()

func formatAlerts(items []alertItem) string {
	var b strings.Builder
	b.WriteString("🛠️ _Copiloto · log_")
	for i, it := range items {
		if i == alertBatchMax {
			fmt.Fprintf(&b, "\n… +%d", len(items)-alertBatchMax)
			break
		}
		label := alertKinds[it.kind]
		if label == "" {
			label = it.kind
		}
		fmt.Fprintf(&b, "\n• %s · %s · %s\n  motivo: %s", chatLabel(it.chat, it.title), time.Unix(it.sent, 0).In(saoPaulo).Format("02/01 15:04"), label, it.reason)
	}
	return b.String()
}

func chatLabel(chat, title string) string {
	title = strings.TrimSpace(strings.ReplaceAll(title, "\n", " "))
	if r := []rune(title); len(r) > 40 {
		title = string(r[:40]) + "…"
	}
	kind := "contato"
	if strings.HasSuffix(chat, "@g.us") {
		kind = "grupo"
	}
	if title == "" {
		return kind + " " + strings.SplitN(chat, "@", 2)[0]
	}
	return kind + " " + title
}

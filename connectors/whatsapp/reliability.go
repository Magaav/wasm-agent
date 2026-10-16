package main

import (
	"context"
	"database/sql"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func splitChats(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, ",")
}
func (j *Journal) hasGap() bool { j.mu.Lock(); defer j.mu.Unlock(); return j.gap }

var errGapMarker = errors.New("persistence_gap_marker_unwritable_operator_reconciliation_required")

func (j *Journal) failPersistence() bool {
	j.mu.Lock()
	j.gap = true
	j.state = "degraded_persistence_gap"
	j.mu.Unlock()
	p := filepath.Join(j.dir, "persistence-gap.json")
	_, err := os.Stat(p)
	if os.IsNotExist(err) {
		err = j.gapWrite(p, []byte("{\"gap\":true,\"reason\":\"durable_processing_failed\"}\n"))
	}
	j.mu.Lock()
	j.gapDurable = err == nil
	if err != nil {
		j.state = "degraded_gap_marker_unwritable"
	}
	j.mu.Unlock()
	if err != nil {
		select {
		case j.fatal <- errGapMarker:
		default:
		}
	}
	return false
}
func (j *Journal) freshness() map[string]any {
	j.mu.Lock()
	defer j.mu.Unlock()
	return map[string]any{"connection": j.state, "source_connection": j.sourceState, "gap_marker_durable": j.gapDurable, "persistence_gap": j.gap, "coverage": "partial; not guaranteed lossless", "snapshot_at": time.Now().Unix()}
}
func (j *Journal) exclude(c Config, m Message, reason string) error {
	// Selected mode reports exclusion counts without retaining unapproved message content/keys.
	chat, id := m.Chat, m.ID
	if len(chat) > 256 {
		chat = "malformed"
	}
	if len(id) > 256 {
		id = "malformed"
	}
	_, err := j.db.Exec("INSERT OR IGNORE INTO excluded VALUES(?,?,?,?,?)", c.Account, c.Generation, chat, id, reason)
	return err
}

type rowQuery interface{ QueryRow(string, ...any) *sql.Row }

func blockedSource(q rowQuery, c Config, chat, id string) (bool, error) {
	var n int
	err := q.QueryRow(`SELECT EXISTS(SELECT 1 FROM source_blocks WHERE account=? AND generation=? AND chat=? AND id=?) OR EXISTS(SELECT 1 FROM chat_holds WHERE account=? AND generation=? AND chat=?)`, c.Account, c.Generation, chat, id, c.Account, c.Generation, chat).Scan(&n)
	return n != 0, err
}
func (j *Journal) mutate(c Config, m Message) error {
	j.effectMu.Lock()
	defer j.effectMu.Unlock()
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.Exec("INSERT OR IGNORE INTO chats VALUES(?,?,?)", c.Account, c.Generation, m.Chat); err != nil {
		return err
	}
	var sender string
	var own bool
	err = tx.QueryRow("SELECT sender,own FROM messages WHERE account=? AND generation=? AND chat=? AND id=?", c.Account, c.Generation, m.Chat, m.Target).Scan(&sender, &own)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	verified := m.Target != "" && len(m.Target) <= 256 && m.MutationScope && (m.OwnerMutation || (err == nil && ((m.Own && own) || (!own && !m.Own && sender == m.Sender))))
	reason := "unproven_mutation_chat_hold"
	if m.OwnerMutation && m.Target == "" {
		reason = "owner_chat_clear_hold"
	}
	if verified {
		reason = "verified_source_" + m.Mutation
		_, err = tx.Exec("INSERT OR IGNORE INTO source_blocks VALUES(?,?,?,?,?)", c.Account, c.Generation, m.Chat, m.Target, reason)
	} else {
		_, err = tx.Exec("INSERT OR IGNORE INTO chat_holds VALUES(?,?,?,?)", c.Account, c.Generation, m.Chat, reason)
	}
	if err != nil {
		return err
	}
	target := m.Target
	if !verified {
		target = ""
	}
	_, err = tx.Exec("UPDATE audio SET state='blocked_source',reason=? WHERE account=? AND generation=? AND chat=? AND (?='' OR id=?) AND state IN ('pending','transcribed')", reason, c.Account, c.Generation, m.Chat, target, target)
	if err != nil {
		return err
	}
	_, err = tx.Exec("UPDATE outbox SET state='blocked',ack=? WHERE account=? AND generation=? AND chat=? AND (?='' OR source=?) AND state='ready'", reason, c.Account, c.Generation, m.Chat, target, target)
	if err != nil {
		return err
	}
	_, err = tx.Exec("INSERT INTO events(kind,at,detail) VALUES('source_mutation',?,?)", time.Now().Unix(), reason)
	if err != nil {
		return err
	}
	return tx.Commit()
}
func (j *Journal) deferPost(c Config, m Message, part int, cause error, fromIntent bool) error {
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	state, reason := "ready", "definite_pre_dispatch_refusal"
	if fromIntent {
		reason = "definite_not_submitted_after_intent"
	}
	var permanent permanentError
	if errors.As(cause, &permanent) {
		state = "blocked"
		reason = string(permanent)
	}
	result, err := tx.Exec("UPDATE outbox SET state=?,ack=? WHERE account=? AND generation=? AND chat=? AND source=? AND part=? AND (state='ready' OR (?=1 AND state='unknown' AND ack='dispatch intent; reconciliation required'))", state, reason, c.Account, c.Generation, m.Chat, m.ID, part, fromIntent)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		return nil
	}
	if fromIntent {
		if _, err = tx.Exec("INSERT INTO events(kind,at,detail) VALUES('definite_not_submitted',?,?)", time.Now().Unix(), reason); err != nil {
			return err
		}
	}
	_, err = tx.Exec("INSERT INTO post_retry VALUES(?,?,?,?,?,?,?) ON CONFLICT(account,generation,chat,source,part) DO UPDATE SET next_attempt=excluded.next_attempt,reason=excluded.reason", c.Account, c.Generation, m.Chat, m.ID, part, time.Now().Add(time.Minute).Unix(), reason)
	if err != nil {
		return err
	}
	return tx.Commit()
}
func serveAPI(server *http.Server, listener net.Listener, ctx context.Context, cancel context.CancelFunc, result chan<- error) {
	err := server.Serve(listener)
	if ctx.Err() != nil {
		result <- nil
	} else {
		result <- errors.New("api_server_stopped_unexpectedly")
	}
	cancel()
	_ = err // All unexpected Serve returns (including external Close) are failure, never success.
}

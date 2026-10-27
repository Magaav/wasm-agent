// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

// Audio compute queue: which pending audio runs next, on which lane, and what a
// failure costs. Posting safety is separate (blockedSource / chat_holds); this file
// only decides local transcription. See docs/WHATSAPP-TRANSCRIPTION.md.

// A chat hold with one of these reasons fences only outbound posting in that chat.
// The revoke behind it carried an exact target ID, and that ID is fenced on its own
// (target_fences), so the rest of the chat's audio can still be transcribed into the
// private journal. Owner clear/delete and untargeted mutations still fence compute.
const postingOnlyHold = "unproven_mutation_chat_hold"

// computeFence is the SQL predicate (over alias a: account,generation,chat,id) that
// keeps a source out of local compute.
const computeFence = ` NOT EXISTS(SELECT 1 FROM source_blocks b WHERE b.account=a.account AND b.generation=a.generation AND b.chat=a.chat AND b.id=a.id)
 AND NOT EXISTS(SELECT 1 FROM target_fences f WHERE f.account=a.account AND f.generation=a.generation AND f.id=a.id)
 AND NOT EXISTS(SELECT 1 FROM chat_holds h WHERE h.account=a.account AND h.generation=a.generation AND h.chat=a.chat AND h.reason!='` + postingOnlyHold + `') `

const (
	maxComputeFailures = 6 // genuine decode failures before a visible terminal state
	freshWindow        = 15 * 60
	expressSeconds     = 90 // express lane takes only audio declared at most this long
)

func installAudioQueue(db *sql.DB) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS target_fences(account TEXT,generation INTEGER,id TEXT,reason TEXT,PRIMARY KEY(account,generation,id))`); err != nil {
		return err
	}
	var present int
	if err := db.QueryRow("SELECT count(*) FROM pragma_table_info('audio') WHERE name='failures'").Scan(&present); err != nil {
		return err
	}
	if present == 0 {
		// Additive: existing rows start with no genuine-failure history, so a task
		// that looped under the old fixed timeout gets the new watchdog from tier 0.
		if _, err := db.Exec("ALTER TABLE audio ADD COLUMN failures INTEGER NOT NULL DEFAULT 0"); err != nil {
			return err
		}
	}
	return nil
}

// blockedCompute is the transcription fence: an exact source block, a fenced
// revoke target ID (any chat: the alias of a DM may differ), or a compute hold.
func blockedCompute(q rowQuery, c Config, chat, id string) (bool, error) {
	var n int
	err := q.QueryRow(`SELECT EXISTS(SELECT 1 FROM (SELECT ? AS account,? AS generation,? AS chat,? AS id) a WHERE NOT(`+computeFence+`))`, c.Account, c.Generation, chat, id).Scan(&n)
	return n != 0, err
}

// postingHeld reports any chat hold, including posting-only ones.
func postingHeld(q rowQuery, c Config, chat string) (bool, error) {
	var n int
	err := q.QueryRow("SELECT EXISTS(SELECT 1 FROM chat_holds WHERE account=? AND generation=? AND chat=?)", c.Account, c.Generation, chat).Scan(&n)
	return n != 0, err
}

// audioSeconds is the sender-declared length from the retained AudioMessage, or 0.
// It only routes work to a lane and seeds the watchdog budget; the worker reports
// the decoded duration, which wins.
func audioSeconds(raw []byte) int {
	var p waE2E.Message
	if len(raw) == 0 || proto.Unmarshal(raw, &p) != nil {
		return 0
	}
	return int(p.GetAudioMessage().GetSeconds())
}

// audioLane is one transcription worker. The main lane takes anything in priority
// order. The express lane exists only so a short voice note is not stuck behind a
// long one: it runs only while the main lane decodes long (or unknown-length)
// audio, and only takes audio declared at most MaxSeconds. Two decodes then share
// the CPU; the short one finishes in seconds instead of waiting minutes.
type audioLane struct {
	Express    bool
	MaxSeconds int
	Work       string // private temporary file name in the state directory
}

var mainLane = audioLane{Work: "audio-work"}

type audioQueue struct {
	mu       sync.Mutex
	inflight map[string]bool
	mainLong bool
	wakes    []chan struct{}
	post     chan struct{}
}

// audioSignal registers a lane's wake channel (capacity 1: wakes coalesce).
func (j *Journal) audioSignal() <-chan struct{} {
	j.queue.mu.Lock()
	defer j.queue.mu.Unlock()
	ch := make(chan struct{}, 1)
	j.queue.wakes = append(j.queue.wakes, ch)
	return ch
}
func (j *Journal) wakeAudio() {
	j.queue.mu.Lock()
	defer j.queue.mu.Unlock()
	for _, ch := range j.queue.wakes {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}
func (j *Journal) postSignal() <-chan struct{} {
	j.queue.mu.Lock()
	defer j.queue.mu.Unlock()
	if j.queue.post == nil {
		j.queue.post = make(chan struct{}, 1)
	}
	return j.queue.post
}
func (j *Journal) wakePost() {
	j.queue.mu.Lock()
	defer j.queue.mu.Unlock()
	if j.queue.post != nil {
		select {
		case j.queue.post <- struct{}{}:
		default:
		}
	}
}

type tieredRecognizer interface {
	TranscribeTier(ctx context.Context, path, language string, tier, seconds int) (string, error)
}

// computeFailure classifies an error: "permanent" (visible unsupported now),
// "cancelled" (shutdown; not the audio's fault), "decode" (the decode itself failed
// or got stuck: counts toward fallback tiers and the terminal state) or
// "environment" (missing cache/interpreter, media download: retried with a
// bounded backoff, never terminal, because it is fixed outside this audio).
func computeFailure(ctx context.Context, err error) string {
	var p permanentError
	switch {
	case errors.As(err, &p):
		return "permanent"
	case errors.Is(err, context.Canceled) || ctx.Err() != nil:
		return "cancelled"
	}
	switch err.Error() {
	case "worker_timeout", "worker_stalled", "worker_eof", "worker_protocol", "worker_compute_failed", "fallback_model_unavailable":
		return "decode"
	}
	return "environment"
}

// backoff doubles from base per prior failure, capped.
func backoff(base, limit time.Duration, n int) time.Duration {
	d := base
	for i := 1; i < n && d < limit; i++ {
		d *= 2
	}
	if d > limit {
		d = limit
	}
	return d
}

// processAudioLane runs at most one pending audio on lane and reports whether it
// claimed one (so the caller drains the queue without waiting for a tick).
func (j *Journal) processAudioLane(ctx context.Context, t Transport, r Recognizer, lane audioLane) (bool, error) {
	c, err := j.Config()
	if err != nil {
		return false, err
	}
	if !c.Requested {
		return false, nil
	}
	if lane.Express {
		j.queue.mu.Lock()
		long := j.queue.mainLong
		j.queue.mu.Unlock()
		if !long {
			return false, nil
		}
	}
	// Priority: never-failed first; within that, audio sent in the last 15 minutes
	// oldest-first (conversation order), then older backlog newest-first, so a
	// requeued or downtime backlog never delays a live voice note. Audio that has
	// genuinely failed runs last and only after its backoff.
	now := time.Now().Unix()
	fresh := now - freshWindow
	rows, err := j.db.Query(`SELECT m.chat,m.id,m.sender,m.body,m.sent,m.own,m.raw,a.language,a.failures FROM audio a JOIN messages m USING(account,generation,chat,id) WHERE a.account=? AND a.generation=? AND a.state='pending' AND`+computeFence+`AND a.next_attempt<=? ORDER BY a.failures>0,m.sent>=? DESC,CASE WHEN m.sent>=? THEN m.sent ELSE -m.sent END,m.observed LIMIT 32`, c.Account, c.Generation, now, fresh, fresh)
	if err != nil {
		return false, err
	}
	var m Message
	var language string
	var failures, seconds int
	found := false
	j.queue.mu.Lock()
	if j.queue.inflight == nil {
		j.queue.inflight = map[string]bool{}
	}
	for rows.Next() {
		var candidate Message
		var lang string
		var fails int
		if err = rows.Scan(&candidate.Chat, &candidate.ID, &candidate.Sender, &candidate.Body, &candidate.Sent, &candidate.Own, &candidate.Raw, &lang, &fails); err != nil {
			break
		}
		if j.queue.inflight[candidate.Chat+"\x00"+candidate.ID] {
			continue
		}
		s := audioSeconds(candidate.Raw)
		if lane.Express && (s <= 0 || s > lane.MaxSeconds) {
			continue
		}
		m, language, failures, seconds, found = candidate, lang, fails, s, true
		break
	}
	key := m.Chat + "\x00" + m.ID
	if found {
		j.queue.inflight[key] = true
		if !lane.Express {
			j.queue.mainLong = seconds <= 0 || seconds > expressSeconds
		}
	}
	j.queue.mu.Unlock()
	rows.Close()
	if err != nil || !found {
		return false, err
	}
	if !lane.Express && (seconds <= 0 || seconds > expressSeconds) {
		j.wakeAudio() // the express lane may now take short audio
	}
	defer func() {
		j.queue.mu.Lock()
		delete(j.queue.inflight, key)
		if !lane.Express {
			j.queue.mainLong = false
		}
		j.queue.mu.Unlock()
	}()
	b, err := t.Download(ctx, m)
	if err == nil && len(b) > 20*1024*1024 {
		err = permanentError("audio_too_large")
	}
	var text string
	if err == nil {
		work := lane.Work
		if work == "" {
			work = mainLane.Work
		}
		path := filepath.Join(j.dir, work)
		err = os.WriteFile(path, b, 0600)
		if err == nil {
			// Fallback tiers only after genuine decode failures: 2 at the configured
			// decode, 2 greedy/no temperature re-decode, then the cheapest decode.
			tier := failures / 2
			if tier > 2 {
				tier = 2
			}
			if tiered, ok := r.(tieredRecognizer); ok {
				text, err = tiered.TranscribeTier(ctx, path, language, tier, seconds)
			} else {
				text, err = r.Transcribe(ctx, path, language)
			}
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
		return true, j.recordComputeFailure(ctx, c, m, failures, err)
	}
	tx, err := j.db.Begin()
	if err != nil {
		return true, err
	}
	defer tx.Rollback()
	// Recheck after compute: a fence that landed meanwhile wins over the result.
	blocked, e := blockedCompute(tx, c, m.Chat, m.ID)
	if e != nil {
		return true, e
	}
	if blocked {
		_, e = tx.Exec("UPDATE audio SET state='blocked_source',reason='source_mutation_or_chat_hold' WHERE account=? AND generation=? AND chat=? AND id=?", c.Account, c.Generation, m.Chat, m.ID)
		if e != nil {
			return true, e
		}
		return true, tx.Commit()
	}
	held, e := postingHeld(tx, c, m.Chat)
	if e != nil {
		return true, e
	}
	reason := ""
	if held {
		// Journal the transcript, never enqueue a post into a held chat. A later
		// release-hold does not replay it either (nothing is in the outbox).
		reason = "posting_held_chat"
	}
	for i, body := range chunks(text) {
		if !c.TranscriptPosting || held {
			continue
		}
		_, err = tx.Exec("INSERT OR IGNORE INTO outbox(account,generation,chat,source,part,body,send_id,state) VALUES(?,?,?,?,?,?,?,'ready')", c.Account, c.Generation, m.Chat, m.ID, i, body, t.NewID())
		if err != nil {
			return true, err
		}
	}
	_, err = tx.Exec("UPDATE audio SET state='transcribed',reason=?,transcript=? WHERE account=? AND generation=? AND chat=? AND id=? AND state='pending'", reason, text, c.Account, c.Generation, m.Chat, m.ID)
	if err != nil {
		return true, err
	}
	if err = tx.Commit(); err != nil {
		return true, err
	}
	j.wakePost()
	return true, nil
}

func (j *Journal) recordComputeFailure(ctx context.Context, c Config, m Message, failures int, cause error) error {
	reason := safeReason(cause)
	state, next, failed := "pending", time.Now(), failures
	switch computeFailure(ctx, cause) {
	case "permanent":
		state = "unsupported"
	case "cancelled":
		// Shutdown: retry immediately on the next start, no penalty.
		_, err := j.db.Exec("UPDATE audio SET reason=? WHERE account=? AND generation=? AND chat=? AND id=? AND state='pending'", reason, c.Account, c.Generation, m.Chat, m.ID)
		return err
	case "decode":
		failed++
		if failed >= maxComputeFailures {
			// Every tier, including the cheapest decode, failed: visible terminal state.
			state, reason = "failed", "stt_exhausted_"+reason
		}
		next = next.Add(backoff(30*time.Second, time.Hour, failed))
	default:
		var attempts int
		j.db.QueryRow("SELECT attempts FROM audio WHERE account=? AND generation=? AND chat=? AND id=?", c.Account, c.Generation, m.Chat, m.ID).Scan(&attempts)
		next = next.Add(backoff(time.Minute, 10*time.Minute, attempts+1))
	}
	_, err := j.db.Exec("UPDATE audio SET state=?,reason=?,attempts=attempts+1,failures=?,next_attempt=? WHERE account=? AND generation=? AND chat=? AND id=? AND state='pending'", state, reason, failed, next.Unix(), c.Account, c.Generation, m.Chat, m.ID)
	return err
}

// requeueReport counts what requeueHeldAudio did or would do. It carries no chat,
// message ID or content: the operator sees counts on the terminal.
type requeueReport struct {
	Applied             bool `json:"applied"`
	Requeued            int  `json:"requeued_pending"`
	BeforeActivation    int  `json:"set_journal_only_before_activation"`
	Unsupported         int  `json:"set_unsupported"`
	SkippedRevoked      int  `json:"skipped_revoked_or_fenced_target"`
	SkippedPossible     int  `json:"skipped_possible_target_legacy_hold"`
	SkippedLegacy       int  `json:"skipped_legacy_hold_needs_flag"`
	SkippedOtherHold    int  `json:"skipped_owner_or_untargeted_hold"`
	SkippedOtherReason  int  `json:"skipped_other_block_reason"`
	SkippedLimit        int  `json:"skipped_over_limit"`
	LegacyHoldsIncluded bool `json:"legacy_holds_included"`
}

// requeueHeldAudio is the OFFLINE operator recovery for audio that is
// blocked_source only because its chat carries a posting-only hold (an unproven
// revoke), newest first. Idempotent: it only moves rows still blocked_source, and
// a second run finds nothing. It never touches a row whose own ID is a recorded
// revoke target or source block, never touches owner clear/delete holds, never
// releases a hold, never creates an outbox row and never replays a post: requeued
// audio is transcribed into the journal and stays unposted while the chat is held.
//
// Holds created before hold_origins existed ("legacy") have no recorded target.
// Their audio that was already in the chat when the hold landed may BE the revoked
// message, so it is never requeued here. Audio that arrived after such a hold is
// requeued only with includeLegacy, an explicit operator decision.
func (j *Journal) requeueHeldAudio(c Config, limit int, includeLegacy, apply bool) (requeueReport, error) {
	report := requeueReport{Applied: apply, LegacyHoldsIncluded: includeLegacy}
	tx, err := j.db.Begin()
	if err != nil {
		return report, err
	}
	defer tx.Rollback()
	rows, err := tx.Query(`SELECT a.chat,a.id,a.reason,m.sent,m.unsupported,h.reason,o.chat IS NOT NULL,
 EXISTS(SELECT 1 FROM source_blocks b WHERE b.account=a.account AND b.generation=a.generation AND b.chat=a.chat AND b.id=a.id)
 OR EXISTS(SELECT 1 FROM target_fences f WHERE f.account=a.account AND f.generation=a.generation AND f.id=a.id)
 OR EXISTS(SELECT 1 FROM mutation_evidence e WHERE e.account=a.account AND e.generation=a.generation AND e.target=a.id),
 EXISTS(SELECT 1 FROM mutation_evidence e WHERE e.account=a.account AND e.generation=a.generation AND e.chat=a.chat AND e.decision='chat_hold' AND e.target='')
 FROM audio a JOIN messages m USING(account,generation,chat,id)
 JOIN chat_holds h ON h.account=a.account AND h.generation=a.generation AND h.chat=a.chat
 LEFT JOIN hold_origins o ON o.account=a.account AND o.generation=a.generation AND o.chat=a.chat
 WHERE a.account=? AND a.generation=? AND a.state='blocked_source'
 ORDER BY m.sent DESC,m.observed DESC,a.rowid DESC`, c.Account, c.Generation)
	if err != nil {
		return report, err
	}
	type move struct{ chat, id, state, reason string }
	var moves []move
	for rows.Next() {
		var chat, id, reason, unsupported, hold string
		var sent int64
		var origin, revoked, untargeted bool
		if err = rows.Scan(&chat, &id, &reason, &sent, &unsupported, &hold, &origin, &revoked, &untargeted); err != nil {
			rows.Close()
			return report, err
		}
		switch {
		case hold != postingOnlyHold || untargeted:
			// Owner clear/delete, or a recorded mutation with no target ID: any
			// audio in the chat may be the affected one.
			report.SkippedOtherHold++
			continue
		case reason != "source_mutation_or_chat_hold" && reason != postingOnlyHold:
			report.SkippedOtherReason++ // e.g. verified_source_revoke: its own message
			continue
		case revoked:
			report.SkippedRevoked++
			continue
		case !origin && reason == postingOnlyHold:
			report.SkippedPossible++
			continue
		case !origin && !includeLegacy:
			report.SkippedLegacy++
			continue
		}
		if limit > 0 && len(moves) >= limit {
			report.SkippedLimit++
			continue
		}
		next := move{chat, id, "pending", "requeued_from_chat_hold"}
		switch {
		case unsupported != "":
			next.state, next.reason = "unsupported", unsupported
		case c.Activated == 0 || sent < c.Activated:
			next.state, next.reason = "journal_only", "before_activation"
		}
		moves = append(moves, next)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return report, err
	}
	for _, mv := range moves {
		switch mv.state {
		case "pending":
			report.Requeued++
		case "journal_only":
			report.BeforeActivation++
		default:
			report.Unsupported++
		}
		if !apply {
			continue
		}
		if _, err = tx.Exec("UPDATE audio SET state=?,reason=?,attempts=0,failures=0,next_attempt=0 WHERE account=? AND generation=? AND chat=? AND id=? AND state='blocked_source'", mv.state, mv.reason, c.Account, c.Generation, mv.chat, mv.id); err != nil {
			return report, err
		}
	}
	if !apply {
		return report, nil
	}
	if _, err = tx.Exec("INSERT INTO events(kind,at,detail) VALUES('held_audio_requeued',?,?)", time.Now().Unix(), requeueDetail(report)); err != nil {
		return report, err
	}
	return report, tx.Commit()
}
func requeueDetail(r requeueReport) string {
	return "pending=" + strconv.Itoa(r.Requeued) + " journal_only=" + strconv.Itoa(r.BeforeActivation) + " unsupported=" + strconv.Itoa(r.Unsupported) + " legacy_included=" + map[bool]string{true: "1", false: "0"}[r.LegacyHoldsIncluded]
}

// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"database/sql"
	"errors"
	"strconv"
	"time"
)

// Re-proving posting holds from the journal (29/10). A posting-only hold
// (postingOnlyHold) exists because a revoke/edit arrived whose key named a
// different JID than the chat it was delivered in, typically a DM journaled
// under its @lid while the key carried the PN. Since 27/10 the live mapper asks
// the device store (sdk_lid_store), but holds created before that stay forever:
// on openclaw a DM's voice notes were transcribed and never posted for 8 days.
//
// The journal itself can prove such a hold: when EVERY unproven mutation recorded
// for the chat names a target ID that is a message journaled in THAT chat, by the
// same author (same rules as mutationProof), the mutation is exactly that
// message's revoke/edit. The hold is then replaced by exact source fences, as the
// live path would have done with the alias in hand. Anything less stays held:
// legacy holds with no recorded evidence, untargeted mutations, targets not in
// the chat, ambiguous or mismatched authors, owner and compute holds.
// Offline (owner lock), dry run unless apply, counts only; nothing is replayed.

type reproveReport struct {
	Applied              bool `json:"applied"`
	Reproved             int  `json:"holds_reproved"`
	Fenced               int  `json:"targets_fenced"`
	SkippedOtherHold     int  `json:"skipped_owner_or_compute_hold"`
	SkippedLegacy        int  `json:"skipped_legacy_hold_no_evidence"`
	SkippedUntargeted    int  `json:"skipped_untargeted_mutation"`
	SkippedTargetMissing int  `json:"skipped_target_not_in_chat"`
	SkippedAuthor        int  `json:"skipped_author_unproven"`
}

type holdEvidence struct {
	target, sender, senderAlt, kind, stage string
	own                                    bool
}

func (j *Journal) reproveHolds(c Config, apply bool) (reproveReport, error) {
	report := reproveReport{Applied: apply}
	j.effectMu.Lock()
	defer j.effectMu.Unlock()
	tx, err := j.db.Begin()
	if err != nil {
		return report, err
	}
	defer tx.Rollback()
	rows, err := tx.Query(`SELECT h.chat,h.reason,o.chat IS NOT NULL FROM chat_holds h
 LEFT JOIN hold_origins o ON o.account=h.account AND o.generation=h.generation AND o.chat=h.chat
 WHERE h.account=? AND h.generation=? ORDER BY h.chat`, c.Account, c.Generation)
	if err != nil {
		return report, err
	}
	type hold struct {
		chat, reason string
		origin       bool
	}
	var holds []hold
	for rows.Next() {
		var h hold
		if err = rows.Scan(&h.chat, &h.reason, &h.origin); err != nil {
			rows.Close()
			return report, err
		}
		holds = append(holds, h)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return report, err
	}
	for _, h := range holds {
		if h.reason != postingOnlyHold {
			report.SkippedOtherHold++
			continue
		}
		if !h.origin {
			report.SkippedLegacy++ // created before evidence was recorded: unknown mutation
			continue
		}
		evidence, err := holdEvidenceRows(tx, c, h.chat)
		if err != nil {
			return report, err
		}
		if len(evidence) == 0 {
			report.SkippedLegacy++
			continue
		}
		verdict := ""
		for _, e := range evidence {
			if verdict = reproveOne(tx, c, h.chat, e); verdict != "" {
				break
			}
		}
		switch verdict {
		case "untargeted":
			report.SkippedUntargeted++
			continue
		case "target_missing":
			report.SkippedTargetMissing++
			continue
		case "author":
			report.SkippedAuthor++
			continue
		case "":
		default:
			return report, errors.New(verdict)
		}
		report.Reproved++
		for _, e := range evidence {
			report.Fenced++
			if !apply {
				continue
			}
			reason := "verified_source_" + e.kind + "_journal_reproof"
			if _, err = tx.Exec("INSERT OR IGNORE INTO source_blocks VALUES(?,?,?,?,?)", c.Account, c.Generation, h.chat, e.target, reason); err != nil {
				return report, err
			}
			// The revoked message's own audio and posts stay fenced, as on the live verified path.
			if _, err = tx.Exec("UPDATE audio SET state='blocked_source',reason=? WHERE account=? AND generation=? AND chat=? AND id=? AND state IN ('pending','transcribed','failed')", reason, c.Account, c.Generation, h.chat, e.target); err != nil {
				return report, err
			}
			if _, err = tx.Exec("UPDATE outbox SET state='blocked',ack=? WHERE account=? AND generation=? AND chat=? AND source=? AND state='ready'", reason, c.Account, c.Generation, h.chat, e.target); err != nil {
				return report, err
			}
		}
		if apply {
			if _, err = tx.Exec("DELETE FROM chat_holds WHERE account=? AND generation=? AND chat=? AND reason=?", c.Account, c.Generation, h.chat, postingOnlyHold); err != nil {
				return report, err
			}
		}
	}
	if !apply || report.Reproved == 0 {
		return report, nil
	}
	if _, err = tx.Exec("INSERT INTO events(kind,at,detail) VALUES('hold_reproved',?,?)", time.Now().Unix(), "holds="+strconv.Itoa(report.Reproved)+" fences="+strconv.Itoa(report.Fenced)); err != nil {
		return report, err
	}
	return report, tx.Commit()
}

func holdEvidenceRows(tx *sql.Tx, c Config, chat string) ([]holdEvidence, error) {
	rows, err := tx.Query(`SELECT COALESCE(target,''),COALESCE(sender,''),COALESCE(sender_alt,''),COALESCE(kind,''),COALESCE(stage,''),COALESCE(own,0)
 FROM mutation_evidence WHERE account=? AND generation=? AND chat=? AND decision='chat_hold' ORDER BY seq`, c.Account, c.Generation, chat)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []holdEvidence
	for rows.Next() {
		var e holdEvidence
		if err = rows.Scan(&e.target, &e.sender, &e.senderAlt, &e.kind, &e.stage, &e.own); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// reproveOne returns "" when the journal proves this recorded mutation names a
// message of this chat by the same author; otherwise why not.
func reproveOne(tx *sql.Tx, c Config, chat string, e holdEvidence) string {
	if e.target == "" || len(e.target) > 256 || e.stage == "owner" || (e.kind != "revoke" && e.kind != "edit") {
		return "untargeted"
	}
	var sender string
	var own bool
	err := tx.QueryRow("SELECT sender,own FROM messages WHERE account=? AND generation=? AND chat=? AND id=?", c.Account, c.Generation, chat, e.target).Scan(&sender, &own)
	if errors.Is(err, sql.ErrNoRows) {
		return "target_missing" // never seen here (or before history): not provable
	}
	if err != nil {
		return err.Error()
	}
	var alt string
	var indexedOwn, ambiguous bool
	var indexed string
	ie := tx.QueryRow("SELECT sender,own,alt,ambiguous FROM source_authors WHERE account=? AND generation=? AND chat=? AND id=?", c.Account, c.Generation, chat, e.target).Scan(&indexed, &indexedOwn, &alt, &ambiguous)
	if ie != nil && !errors.Is(ie, sql.ErrNoRows) {
		return ie.Error()
	}
	if ie == nil && ambiguous {
		return "author"
	}
	if ie != nil || indexed != sender || indexedOwn != own {
		alt = ""
	}
	if (e.own && own) || (!own && !e.own && authorEquivalent(sender, alt, e.sender, e.senderAlt)) {
		return ""
	}
	return "author"
}

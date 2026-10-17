// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

// Recipient delivery/read for OUR OWN outbound operator text is a recorded
// observation, never an inference. The only source is the pinned SDK's receipt
// event, matched to an exact durable intent by account/generation, exact chat
// (or the physical route frozen at prepare time) and the preallocated message
// ID. No body similarity, timing, own echo or display name is used, and no
// receipt path ever sends, resends, reconciles or clears anything.

import (
	"database/sql"
	"errors"
	"time"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

const (
	// Bounded receipt audit history. Eviction drops the OLDEST audit rows only;
	// each intent's observed receipt state is a separate column and is never
	// evicted, so a durable "delivered"/"read" fact cannot be lost by eviction.
	operatorReceiptHistoryLimit = 256
	// One SDK receipt carries a bounded ID list; IDs beyond this are ignored.
	operatorReceiptMaxIDs = 64
)

// Additive migration for journals created before receipt observation existed.
// Old rows keep explicit unknown (zero) receipt state, which is honest: a
// journal written before this feature observed no recipient receipt.
func migrateOperatorReceipts(db *sql.DB) error {
	rows, err := db.Query("PRAGMA table_info(operator_intents)")
	if err != nil {
		return err
	}
	columns := map[string]bool{}
	for rows.Next() {
		var cid, notnull, pk int
		var name, typ string
		var def any
		if err = rows.Scan(&cid, &name, &typ, &notnull, &def, &pk); err != nil {
			rows.Close()
			return err
		}
		columns[name] = true
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, col := range []struct{ name, decl string }{
		{"receipt_delivered", "INTEGER NOT NULL DEFAULT 0"},
		{"receipt_read", "INTEGER NOT NULL DEFAULT 0"},
		{"receipt_basis", "TEXT NOT NULL DEFAULT ''"},
	} {
		if !columns[col.name] {
			if _, err = db.Exec("ALTER TABLE operator_intents ADD COLUMN " + col.name + " " + col.decl); err != nil {
				return err
			}
		}
	}
	return nil
}

// operatorReceiptState maps a pinned-SDK receipt type to observed recipient
// state. Only two of the SDK's receipt values are recipient delivery/read
// evidence for a message WE sent:
//
//	types.ReceiptTypeDelivered ("" )     the recipient device got the message
//	types.ReceiptTypeRead      ("read")  the recipient opened the chat and saw it
//
// Every other value stays explicitly unknown, including:
//
//	sender      one of OUR other devices received it, not the recipient
//	read-self   the reader disabled read receipts; official apps hide this
//	inactive    recipient client not active/foreground; not rendered upstream
//	retry       recipient device failed to decrypt (separate retry path)
//	played / server-error / peer_msg / hist_sync  unrelated protocol states
func operatorReceiptState(t types.ReceiptType) (string, bool) {
	switch t {
	case types.ReceiptTypeDelivered:
		return "delivered", true
	case types.ReceiptTypeRead:
		return "read", true
	}
	return "", false
}

// operatorReceiptStates reports what was OBSERVED, independently per dimension:
// a read observation does not by itself become a recorded delivery observation.
func operatorReceiptStates(deliveredAt, readAt int64) (string, string) {
	delivery, read := "unknown", "unknown"
	if deliveredAt > 0 {
		delivery = "delivered"
	}
	if readAt > 0 {
		read = "read"
	}
	return delivery, read
}

// observeReceipt is called from the SDK event path. It is a bounded local
// transaction: no network/upstream work, no identity/effect lock, no sticky
// persistence-gap marker and no acknowledgement of a claim we did not record.
// A failure is surfaced as a visible counter (and a bounded event reason) while
// the delivery/read state stays explicitly unknown.
func (j *Journal) observeReceipt(e *events.Receipt) {
	if e == nil {
		return
	}
	state, ok := operatorReceiptState(e.Type)
	if !ok {
		j.countReceipt("ignored")
		return
	}
	c, err := j.Config()
	if err != nil {
		j.countReceipt("failed")
		return
	}
	chat := e.Chat.ToNonAD().String()
	if !validChat(chat) || len(e.MessageIDs) == 0 || len(e.MessageIDs) > operatorReceiptMaxIDs {
		j.countReceipt("ignored")
		return
	}
	basis := "observed recipient delivery receipt (pinned SDK delivered type)"
	if state == "read" {
		basis = "observed recipient read receipt (pinned SDK read type)"
	}
	if !j.projectReceipt(c, chat, e.MessageIDs, state, basis) {
		j.countReceipt("failed")
		// Best-effort bounded durable reason on a free connection; it is never
		// turned into a sticky gap or into an unproven delivery claim.
		j.event("receipt_persistence_failed", "observed recipient receipt not projected; delivery/read stays unknown")
	}
}

// projectReceipt returns true when the receipt was handled (projected, ignored
// or unmatched) and false on a real local persistence failure.
func (j *Journal) projectReceipt(c Config, chat string, ids []types.MessageID, state, basis string) bool {
	now := time.Now().Unix()
	tx, err := j.db.Begin()
	if err != nil {
		return false
	}
	defer tx.Rollback()
	for _, id := range ids {
		if id == "" || len(id) > 256 {
			j.countReceipt("ignored")
			continue
		}
		var intentID, intentState string
		var delivered, read int64
		err = tx.QueryRow("SELECT id,state,receipt_delivered,receipt_read FROM operator_intents WHERE account=? AND generation=? AND (chat=? OR route=?) AND send_id=?", c.Account, c.Generation, chat, chat, id).Scan(&intentID, &intentState, &delivered, &read)
		if errors.Is(err, sql.ErrNoRows) {
			// A receipt for a message we never dispatched is not ours to map.
			j.countReceipt("unmatched")
			continue
		}
		if err != nil {
			return false
		}
		if intentState != "accepted" && intentState != "echo_confirmed" {
			// Never project onto an unresolved/held dispatch: a receipt must not
			// settle, resurrect or replace an unknown/held send state.
			j.countReceipt("ignored")
			continue
		}
		changed := false
		if state == "delivered" && delivered == 0 {
			if _, err = tx.Exec("UPDATE operator_intents SET receipt_delivered=?,receipt_basis=? WHERE id=? AND receipt_delivered=0", now, basis, intentID); err != nil {
				return false
			}
			changed = true
		}
		if state == "read" && read == 0 {
			if _, err = tx.Exec("UPDATE operator_intents SET receipt_read=?,receipt_basis=? WHERE id=? AND receipt_read=0", now, basis, intentID); err != nil {
				return false
			}
			changed = true
		}
		if !changed {
			continue
		}
		if _, err = tx.Exec("INSERT INTO operator_receipts(intent,account,generation,chat,send_id,state,at,basis) VALUES(?,?,?,?,?,?,?,?)", intentID, c.Account, c.Generation, chat, id, state, now, basis); err != nil {
			return false
		}
	}
	// Explicit and safe eviction of the bounded audit history only.
	if _, err = tx.Exec("DELETE FROM operator_receipts WHERE seq IN (SELECT seq FROM operator_receipts ORDER BY seq DESC LIMIT -1 OFFSET ?)", operatorReceiptHistoryLimit); err != nil {
		return false
	}
	return tx.Commit() == nil
}

func (j *Journal) countReceipt(kind string) {
	j.mu.Lock()
	switch kind {
	case "unmatched":
		j.receiptUnmatched++
	case "ignored":
		j.receiptIgnored++
	default:
		j.receiptFailures++
	}
	j.mu.Unlock()
}

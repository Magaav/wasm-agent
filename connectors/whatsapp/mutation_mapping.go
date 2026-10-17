package main

import (
	"database/sql"
	"errors"
	"time"

	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

func validUserID(s string) bool {
	j, err := types.ParseJID(s)
	return err == nil && validChat(s) && (j.Server == types.DefaultUserServer || j.Server == types.HiddenUserServer) && j.ToNonAD().String() == s
}
func safeAlternate(primary, alternate types.JID) string {
	p, a := primary.ToNonAD(), alternate.ToNonAD()
	if !validUserID(p.String()) || !validUserID(a.String()) || p.Server == a.Server {
		return ""
	}
	return a.String()
}
func mutationScope(e *events.Message, remote string) (bool, string) {
	if remote == "" {
		return true, "sdk_envelope"
	}
	r, err := types.ParseJID(remote)
	if err != nil {
		return false, "remote_mismatch"
	}
	r = r.ToNonAD()
	chat := e.Info.Chat.ToNonAD()
	if r == chat {
		return true, "normalized_remote"
	}
	if !e.Info.IsGroup {
		alt := safeAlternate(chat, e.Info.RecipientAlt)
		if !e.Info.IsFromMe && chat == e.Info.Sender.ToNonAD() {
			alt = safeAlternate(chat, e.Info.SenderAlt)
		}
		if alt != "" && r.String() == alt {
			return true, "sdk_dm_alias"
		}
	}
	return false, "remote_mismatch"
}
func authorEquivalent(a, altA, b, altB string) bool {
	if !validUserID(a) || !validUserID(b) {
		return false
	}
	return a == b || (validUserID(altA) && altA == b) || (validUserID(altB) && altB == a)
}
func sourceAlternate(m Message) string {
	p, err := types.ParseJID(m.Sender)
	if err != nil {
		return ""
	}
	a, err := types.ParseJID(m.SenderAlt)
	if err != nil {
		return ""
	}
	return safeAlternate(p, a)
}
func storeSourceAuthor(tx *sql.Tx, c Config, m Message, provenance string) error {
	if !validUserID(m.Sender) || m.ID == "" || len(m.ID) > 256 {
		return nil
	}
	alt := sourceAlternate(m)
	var sender, oldAlt string
	var own, ambiguous bool
	err := tx.QueryRow("SELECT sender,own,alt,ambiguous FROM source_authors WHERE account=? AND generation=? AND chat=? AND id=?", c.Account, c.Generation, m.Chat, m.ID).Scan(&sender, &own, &oldAlt, &ambiguous)
	if errors.Is(err, sql.ErrNoRows) {
		_, err = tx.Exec("INSERT INTO source_authors(account,generation,chat,id,sender,own,alt,provenance) VALUES(?,?,?,?,?,?,?,?)", c.Account, c.Generation, m.Chat, m.ID, m.Sender, m.Own, alt, provenance)
		return err
	}
	if err != nil {
		return err
	}
	if own != m.Own || !authorEquivalent(sender, oldAlt, m.Sender, alt) || (oldAlt != "" && alt != "" && sender == m.Sender && oldAlt != alt) {
		ambiguous = true
	}
	if oldAlt == "" && sender == m.Sender {
		oldAlt = alt
	}
	_, err = tx.Exec("UPDATE source_authors SET alt=?,ambiguous=? WHERE account=? AND generation=? AND chat=? AND id=?", oldAlt, ambiguous, c.Account, c.Generation, m.Chat, m.ID)
	return err
}
func (j *Journal) historyAuthor(c Config, m Message) error {
	if !validChat(m.Chat) || (!c.AllChats && !contains(c.Chats, m.Chat)) || m.ID == "" || len(m.ID) > 256 {
		return nil
	}
	j.identityMu.Lock()
	defer j.identityMu.Unlock()
	if _, err := j.scope(c.Account, c.Generation, m.Chat); err != nil {
		return err
	}
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = storeSourceAuthor(tx, c, m, "sdk_history_batch"); err != nil {
		return err
	}
	return tx.Commit()
}
func mutationProof(tx *sql.Tx, c Config, m Message) (bool, string, error) {
	if m.OwnerMutation && m.Target == "" {
		return false, "owner_chat_operation", nil
	}
	if m.Target == "" {
		return false, "target_id_missing", nil
	}
	if len(m.Target) > 256 {
		return false, "target_id_invalid", nil
	}
	if !m.MutationScope {
		return false, "scope_unproven", nil
	}
	if m.OwnerMutation {
		return true, "owner_sdk_event", nil
	}
	var sender string
	var own bool
	err := tx.QueryRow("SELECT sender,own FROM messages WHERE account=? AND generation=? AND chat=? AND id=?", c.Account, c.Generation, m.Chat, m.Target).Scan(&sender, &own)
	originalMissing := errors.Is(err, sql.ErrNoRows)
	if err != nil && !originalMissing {
		return false, "", err
	}
	var indexed, indexAlt, provenance string
	var indexedOwn, ambiguous bool
	ie := tx.QueryRow("SELECT sender,own,alt,ambiguous,provenance FROM source_authors WHERE account=? AND generation=? AND chat=? AND id=?", c.Account, c.Generation, m.Chat, m.Target).Scan(&indexed, &indexedOwn, &indexAlt, &ambiguous, &provenance)
	if ie != nil && !errors.Is(ie, sql.ErrNoRows) {
		return false, "", ie
	}
	if ie == nil && ambiguous {
		return false, "ambiguous_author", nil
	}
	if originalMissing {
		if ie != nil {
			return false, "target_missing", nil
		}
		sender, own = indexed, indexedOwn
	}
	alt := ""
	if ie == nil && indexed == sender && indexedOwn == own {
		alt = indexAlt
	}
	verified := (m.Own && own) || (!own && !m.Own && authorEquivalent(sender, alt, m.Sender, sourceAlternate(m)))
	if !verified {
		return false, "author_mismatch", nil
	}
	if originalMissing {
		return true, "sdk_history_batch", nil
	}
	if sender != m.Sender && !m.Own {
		return true, "sdk_author_alias", nil
	}
	return true, "stored_exact", nil
}
func recordMutationProof(tx *sql.Tx, c Config, m Message, author, decision string, newHold bool) error {
	scope := m.ScopeProof
	switch scope {
	case "sdk_edit_envelope", "sdk_envelope", "normalized_remote", "sdk_dm_alias", "remote_mismatch":
	default:
		scope = "caller_scoped"
		if !m.MutationScope {
			scope = "remote_mismatch"
		}
	}
	stage := "live"
	if m.OwnerMutation {
		scope = "owner_sdk_event"
	}
	if m.History {
		stage = "history"
	}
	if m.OwnerMutation {
		stage = "owner"
	}
	_, err := tx.Exec("INSERT INTO mutation_diagnostics VALUES(?,?,?,?,?,?,?,1) ON CONFLICT(account,generation,chat,stage,scope_proof,author_proof,decision) DO UPDATE SET n=n+1", c.Account, c.Generation, m.Chat, stage, scope, author, decision)
	if err != nil {
		return err
	}
	target := m.Target
	if len(target) > 256 {
		target = ""
	}
	sender := m.Sender
	if !validUserID(sender) {
		sender = ""
	}
	_, err = tx.Exec("INSERT INTO mutation_evidence(account,generation,chat,target,sender,sender_alt,own,kind,scope_proof,author_proof,stage,decision,at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", c.Account, c.Generation, m.Chat, target, sender, sourceAlternate(m), m.Own, m.Mutation, scope, author, stage, decision, time.Now().Unix())
	if err != nil {
		return err
	}
	if newHold {
		_, err = tx.Exec("INSERT OR IGNORE INTO hold_origins VALUES(?,?,?,1)", c.Account, c.Generation, m.Chat)
	}
	return err
}

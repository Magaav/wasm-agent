// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

// Operator-directed protocol text is NOT the event responder. Credentials for
// preparation/dispatch and approval are separately provisioned owner capabilities.
// Neither the read API token nor request role/approval booleans grant them.
import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"go.mau.fi/whatsmeow/types"
)

type operatorRequest struct {
	Account    string   `json:"account"`
	Generation int64    `json:"generation"`
	Chat       string   `json:"conversation_id"`
	Body       string   `json:"body"`
	Reply      string   `json:"reply_to,omitempty"`
	Mentions   []string `json:"mentions,omitempty"`
	Intent     string   `json:"intent_id,omitempty"`
	Digest     string   `json:"approval_digest,omitempty"`
	// resolved carries the transport-proven mention entries for THIS request.
	// It is never decoded from JSON: an operator cannot supply its own proof.
	resolved []operatorMention
}
type operatorIntent struct {
	Canonical  string            `json:"canonical_recipient"`
	Route      string            `json:"protocol_recipient"`
	ID         string            `json:"intent_id"`
	Account    string            `json:"account"`
	Generation int64             `json:"generation"`
	Chat       string            `json:"conversation_id"`
	Body       string            `json:"body"`
	Reply      string            `json:"reply_to"`
	Mentions   []operatorMention `json:"mentions,omitempty"`
	SendID     string            `json:"message_id"`
	Digest     string            `json:"approval_digest"`
	State      string            `json:"state"`
	Revision   int64             `json:"mutation_revision"`
	Source     string            `json:"-"`
	Prepared   int64             `json:"prepared_at"`
	Reason     string            `json:"reason"`
	// Recipient receipt observation for THIS intent's preallocated message ID.
	// Zero means never observed: acceptance is not delivery and absence is not
	// non-delivery. Filled only by observeReceipt from an exact chat/ID match.
	DeliveredAt  int64  `json:"recipient_delivered_at"`
	ReadAt       int64  `json:"recipient_read_at"`
	ReceiptBasis string `json:"receipt_basis,omitempty"`
}

func digest(v any) string {
	b, _ := json.Marshal(v)
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}
func installOperator(db *sql.DB) error {
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS operator_intents(
 id TEXT PRIMARY KEY,account TEXT NOT NULL,generation INTEGER NOT NULL,chat TEXT NOT NULL,canonical TEXT NOT NULL,route TEXT NOT NULL,
 body TEXT NOT NULL,reply TEXT NOT NULL,mentions TEXT NOT NULL DEFAULT '',send_id TEXT NOT NULL UNIQUE,digest TEXT NOT NULL,
 state TEXT NOT NULL,revision INTEGER NOT NULL,source TEXT NOT NULL,prepared INTEGER NOT NULL,reason TEXT NOT NULL);
 CREATE INDEX IF NOT EXISTS operator_hold_account_state ON operator_intents(account,state);
 CREATE TABLE IF NOT EXISTS operator_revisions(account TEXT,generation INTEGER,chat TEXT,revision INTEGER NOT NULL,PRIMARY KEY(account,generation,chat));
 CREATE TRIGGER IF NOT EXISTS operator_source_block AFTER INSERT ON source_blocks BEGIN
 INSERT INTO operator_revisions VALUES(NEW.account,NEW.generation,NEW.chat,1) ON CONFLICT(account,generation,chat) DO UPDATE SET revision=revision+1; END;
 CREATE TRIGGER IF NOT EXISTS operator_chat_hold AFTER INSERT ON chat_holds BEGIN
 INSERT INTO operator_revisions VALUES(NEW.account,NEW.generation,NEW.chat,1) ON CONFLICT(account,generation,chat) DO UPDATE SET revision=revision+1; END;
 CREATE TABLE IF NOT EXISTS operator_receipts(seq INTEGER PRIMARY KEY AUTOINCREMENT,intent TEXT NOT NULL,account TEXT NOT NULL,generation INTEGER NOT NULL,chat TEXT NOT NULL,send_id TEXT NOT NULL,state TEXT NOT NULL,at INTEGER NOT NULL,basis TEXT NOT NULL);
 CREATE INDEX IF NOT EXISTS operator_receipts_intent ON operator_receipts(intent);`)
	if err != nil {
		return err
	}
	// Additive migrations for journals created before these features existed.
	if err = migrateOperatorMentions(db); err != nil {
		return err
	}
	return migrateOperatorReceipts(db)
}
func canonicalOperatorChat(chat string) bool {
	jid, err := types.ParseJID(chat)
	if err != nil || !validChat(chat) || jid.ToNonAD().String() != chat {
		return false
	}
	// No device-qualified IDs or permissive display/phone normalisation.
	return !strings.ContainsAny(jid.User, ":._")
}
func (j *Journal) operatorContext(q rowQuery, r operatorRequest) (Config, error) {
	var c Config
	var raw string
	err := q.QueryRow("SELECT value FROM config WHERE id=1").Scan(&raw)
	if err == nil {
		err = json.Unmarshal([]byte(raw), &c)
	}
	if err != nil || c.Account != r.Account || c.Generation != r.Generation || (!c.AllChats && !contains(c.Chats, r.Chat)) || !canonicalOperatorChat(r.Chat) {
		return c, errors.New("operator_exact_scope_required")
	}
	j.mu.Lock()
	verified, authenticated, blocked := j.verified, j.authenticated, j.pairingBlocked
	j.mu.Unlock()
	if !verified || !authenticated || blocked || c.PairingRequired || j.hasGap() {
		return c, errors.New("operator_identity_or_persistence_unready")
	}
	var known int
	if r.Chat == c.Account {
		known = 1
	} else if err = q.QueryRow("SELECT EXISTS(SELECT 1 FROM chats WHERE account=? AND generation=? AND chat=?)", c.Account, c.Generation, r.Chat).Scan(&known); err != nil {
		return c, err
	}
	if known != 1 {
		return c, errors.New("operator_recipient_not_observed")
	}
	return c, nil
}
func (j *Journal) operatorSnapshot(q rowQuery, c Config, chat, reply string) (int64, string, error) {
	var revision int64
	if err := q.QueryRow("SELECT COALESCE((SELECT revision FROM operator_revisions WHERE account=? AND generation=? AND chat=?),0)+COALESCE((SELECT max(seq) FROM events WHERE kind='source_mutation'),0)", c.Account, c.Generation, chat).Scan(&revision); err != nil {
		return 0, "", err
	}
	if reply == "" {
		return revision, "", nil
	} // Independent new text never releases historical audio holds.
	blocked, err := blockedSource(q, c, chat, reply)
	if err != nil {
		return 0, "", err
	}
	if blocked {
		return 0, "", errors.New("operator_reply_source_held")
	}
	var body, sender, unsupported string
	var own, audio bool
	var sent, row int64
	err = q.QueryRow("SELECT rowid,CASE WHEN length(CAST(body AS BLOB))<=4096 THEN body ELSE '' END,CASE WHEN length(CAST(sender AS BLOB))<=256 THEN sender ELSE '' END,sent,own,audio,unsupported FROM messages WHERE account=? AND generation=? AND chat=? AND id=?", c.Account, c.Generation, chat, reply).Scan(&row, &body, &sender, &sent, &own, &audio, &unsupported)
	if err != nil {
		return 0, "", errors.New("operator_reply_source_unproven")
	}
	if body == "" || len(body) > 4096 || !utf8.ValidString(body) || sender == "" || sent <= 0 || audio || unsupported != "" {
		return 0, "", errors.New("operator_reply_requires_exact_plain_text_source")
	}
	var newer int
	if err = q.QueryRow("SELECT EXISTS(SELECT 1 FROM messages WHERE account=? AND generation=? AND chat=? AND own=1 AND (rowid>? OR sent>=?) AND id<>?)", c.Account, c.Generation, chat, row, sent, reply).Scan(&newer); err != nil {
		return 0, "", err
	}
	if newer != 0 {
		return 0, "", errors.New("operator_reply_precedence_changed")
	}
	// Any later message changes quote preparation; this is deliberately conservative.
	var last int64
	if err = q.QueryRow("SELECT COALESCE(max(rowid),0) FROM messages WHERE account=? AND generation=? AND chat=?", c.Account, c.Generation, chat).Scan(&last); err != nil {
		return 0, "", err
	}
	return revision, digest([]any{reply, body, sender, sent, own, row, last}), nil
}
func readOperator(q rowQuery, id string) (operatorIntent, error) {
	var i operatorIntent
	var mentions string
	err := q.QueryRow("SELECT id,account,generation,chat,canonical,route,body,reply,send_id,digest,state,revision,source,prepared,reason,receipt_delivered,receipt_read,receipt_basis,COALESCE(mentions,'') FROM operator_intents WHERE id=?", id).Scan(&i.ID, &i.Account, &i.Generation, &i.Chat, &i.Canonical, &i.Route, &i.Body, &i.Reply, &i.SendID, &i.Digest, &i.State, &i.Revision, &i.Source, &i.Prepared, &i.Reason, &i.DeliveredAt, &i.ReadAt, &i.ReceiptBasis, &mentions)
	if err != nil || mentions == "" {
		return i, err
	}
	if err = json.Unmarshal([]byte(mentions), &i.Mentions); err != nil {
		return i, errors.New("operator_mention_record_unreadable")
	}
	return i, nil
}
func intentRequest(i operatorIntent) operatorRequest {
	return operatorRequest{Account: i.Account, Generation: i.Generation, Chat: i.Chat, Body: i.Body, Reply: i.Reply, Mentions: requestedMentionList(i.Mentions)}
}
func (j *Journal) prepareOperator(r operatorRequest, canonical, route string, newID func() string) (operatorIntent, error) {
	var empty operatorIntent
	if canonical == "" || route == "" || !canonicalOperatorChat(canonical) || !canonicalOperatorChat(route) {
		return empty, errors.New("operator_recipient_alias_mapping_unproven")
	}
	if strings.TrimSpace(r.Body) == "" || len(r.Body) > 4096 || !utf8.ValidString(r.Body) || len(r.Reply) > 256 {
		return empty, errors.New("operator_text_invalid_or_too_large")
	}
	// Mentions are proven by the transport and normalized into the text HERE, so
	// the token every reader sees, the id below, the approval digest and the sent
	// bytes are the same text. A named person missing from the text is refused,
	// never injected.
	mentions, err := resolvedOperatorMentions(r)
	if err != nil {
		return empty, err
	}
	body, err := normalizeOperatorMentions(r.Body, mentions)
	if err != nil {
		return empty, err
	}
	if len(body) > 4096 || !utf8.ValidString(body) {
		return empty, errors.New("operator_text_invalid_or_too_large")
	}
	r.Body = body
	// The signature is composed HERE, before the intent is stored, so the body the
	// approval binds and the id below hash the exact text that will be sent. An
	// over-budget result is refused rather than truncated.
	signed, err := operatorSignedBody(r.Body)
	if err != nil {
		return empty, err
	}
	if len(signed) > 4096 || !utf8.ValidString(signed) {
		return empty, errors.New("operator_text_invalid_or_too_large")
	}
	r.Body = signed
	j.identityMu.Lock()
	defer j.identityMu.Unlock()
	j.effectMu.Lock()
	defer j.effectMu.Unlock()
	tx, err := j.db.Begin()
	if err != nil {
		return empty, err
	}
	defer tx.Rollback()
	c, err := j.operatorContext(tx, r)
	if err != nil {
		return empty, err
	}
	id := operatorIntentID(r, canonical, mentions)
	old, err := readOperator(tx, id)
	if err == nil && old.Chat != r.Chat {
		return empty, errors.New("operator_alias_intent_exists_use_original_chat")
	}
	if err == nil && (old.State == "unknown" || old.State == "accepted" || old.State == "echo_confirmed" || old.State == "not_submitted") {
		return old, nil
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return empty, err
	}
	var held int
	if err = tx.QueryRow("SELECT EXISTS(SELECT 1 FROM operator_intents WHERE account=? AND (canonical=? OR chat=? OR route=?) AND state='unknown')", r.Account, canonical, r.Chat, route).Scan(&held); err != nil {
		return empty, err
	}
	if held != 0 {
		return empty, errors.New("operator_unknown_recipient_intent_requires_reconciliation")
	}
	revision, source, err := j.operatorSnapshot(tx, c, r.Chat, r.Reply)
	if err != nil {
		return empty, err
	}
	if old.ID != "" && old.Route == route && old.Revision == revision && old.Source == source && time.Now().Unix()-old.Prepared >= 0 && time.Now().Unix()-old.Prepared <= 600 {
		return old, nil
	}
	sendID := old.SendID
	if sendID == "" {
		sendID = newID()
	}
	if sendID == "" || len(sendID) > 256 {
		return empty, errors.New("operator_message_id_unavailable")
	}
	i := operatorIntent{Canonical: canonical, Route: route, ID: id, Account: r.Account, Generation: r.Generation, Chat: r.Chat, Body: r.Body, Reply: r.Reply, Mentions: mentions, SendID: sendID, State: "prepared", Revision: revision, Source: source, Prepared: time.Now().Unix()}
	// The digest tag is versioned by feature, so an intent prepared before
	// mentions existed keeps the exact digest it was approved under.
	if len(mentions) == 0 {
		i.Digest = digest([]any{"approval-v1", i.ID, i.SendID, i.Route, i.Revision, i.Source, i.Prepared, old.Digest})
	} else {
		i.Digest = digest([]any{"approval-v2", i.ID, i.SendID, i.Route, i.Revision, i.Source, i.Prepared, old.Digest, requestedMentionList(mentions), protocolMentionList(mentions)})
	}
	record, err := operatorMentionRecord(mentions)
	if err != nil {
		return empty, err
	}
	// Receipt columns are intentionally absent here: an update preserves any
	// already-observed recipient receipt rather than resetting it.
	_, err = tx.Exec(`INSERT INTO operator_intents(id,account,generation,chat,canonical,route,body,reply,mentions,send_id,digest,state,revision,source,prepared,reason) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET digest=excluded.digest,route=excluded.route,mentions=excluded.mentions,state='prepared',revision=excluded.revision,source=excluded.source,prepared=excluded.prepared,reason=''`, i.ID, i.Account, i.Generation, i.Chat, i.Canonical, i.Route, i.Body, i.Reply, record, i.SendID, i.Digest, i.State, i.Revision, i.Source, i.Prepared, "")
	if err != nil {
		return empty, err
	}
	return i, tx.Commit()
}
func (j *Journal) validateOperator(q rowQuery, i operatorIntent) error {
	c, err := j.operatorContext(q, intentRequest(i))
	if err != nil {
		return err
	}
	revision, source, err := j.operatorSnapshot(q, c, i.Chat, i.Reply)
	if err != nil {
		return err
	}
	if i.Revision != revision || i.Source != source || time.Now().Unix()-i.Prepared < 0 || time.Now().Unix()-i.Prepared > 600 {
		return errors.New("operator_preparation_stale_reprepare_and_reapprove")
	}
	return nil
}
func (j *Journal) approveOperator(r operatorRequest) (operatorIntent, error) {
	j.identityMu.Lock()
	defer j.identityMu.Unlock()
	j.effectMu.Lock()
	defer j.effectMu.Unlock()
	tx, err := j.db.Begin()
	if err != nil {
		return operatorIntent{}, err
	}
	defer tx.Rollback()
	i, err := readOperator(tx, r.Intent)
	if err != nil {
		return i, errors.New("operator_intent_not_found")
	}
	// Approval must echo the exact account, generation, recipient, Unicode body,
	// quote and mention audience.
	if !sameOperatorBinding(intentRequest(i), operatorRequest{Account: r.Account, Generation: r.Generation, Chat: r.Chat, Body: r.Body, Reply: r.Reply, Mentions: r.Mentions}) || i.Digest != r.Digest {
		return i, errors.New("operator_approval_binding_mismatch")
	}
	if i.State != "prepared" && i.State != "approved" {
		return i, errors.New("operator_intent_already_dispatched")
	}
	if err = j.validateOperator(tx, i); err != nil {
		return i, err
	}
	_, err = tx.Exec("UPDATE operator_intents SET state='approved' WHERE id=?", i.ID)
	if err != nil {
		return i, err
	}
	i.State = "approved"
	return i, tx.Commit()
}

type operatorTransport interface {
	ResolveOperator(context.Context, string) (string, string, error)
	ResolveMentions(context.Context, string, []string) ([]operatorMention, error)
	NewID() string
	SendOperator(context.Context, operatorIntent) (string, error)
}

func (j *Journal) sendOperator(ctx context.Context, r operatorRequest, t operatorTransport) (operatorIntent, error) {
	j.identityMu.Lock()
	j.effectMu.Lock()
	i, err := readOperator(j.db, r.Intent)
	if err == nil && (i.Account != r.Account || i.Generation != r.Generation || i.Chat != r.Chat) {
		err = errors.New("operator_scope_mismatch")
	}
	if err == nil {
		_, err = j.operatorContext(j.db, intentRequest(i))
	}
	if err == nil && i.State == "approved" {
		var held int
		err = j.db.QueryRow("SELECT EXISTS(SELECT 1 FROM operator_intents WHERE account=? AND (canonical=? OR chat=? OR route=?) AND state='unknown' AND id<>?)", i.Account, i.Canonical, i.Chat, i.Route, i.ID).Scan(&held)
		if err == nil && held != 0 {
			err = errors.New("operator_unknown_recipient_intent_requires_reconciliation")
		}
		if err == nil {
			err = j.validateOperator(j.db, i)
		}
		if err == nil {
			_, err = j.db.Exec("UPDATE operator_intents SET state='unknown',reason='durable dispatch intent; no replay' WHERE id=? AND state='approved'", i.ID)
			i.State = "unknown"
			i.Reason = "durable dispatch intent; no replay"
		}
	} else if err == nil {
		j.effectMu.Unlock()
		j.identityMu.Unlock()
		return j.operatorStatus(r)
	}
	j.effectMu.Unlock()
	j.identityMu.Unlock()
	if err != nil {
		return i, err
	}
	// No identity/DB/mutation mutex is held through SDK network/ACK work.
	ack, sendErr := t.SendOperator(ctx, i)
	if sendErr == nil && ack == i.SendID {
		_, err = j.db.Exec("UPDATE operator_intents SET state='accepted',reason='server acceptance; recipient delivery/read unknown' WHERE id=? AND state='unknown'", i.ID)
	} else {
		var notSubmitted notSubmittedError
		if errors.As(sendErr, &notSubmitted) {
			_, err = j.db.Exec("UPDATE operator_intents SET state='not_submitted',reason='owned adapter proved SDK not invoked; no automatic retry' WHERE id=? AND state='unknown'", i.ID)
		}
	}
	if err != nil {
		return i, errors.New("operator_outcome_persistence_unknown")
	}
	return j.operatorStatus(r)
}
func (j *Journal) operatorStatus(r operatorRequest) (operatorIntent, error) {
	i, err := readOperator(j.db, r.Intent)
	if err != nil {
		return i, errors.New("operator_intent_not_found")
	}
	if i.Account != r.Account || i.Generation != r.Generation || i.Chat != r.Chat {
		return operatorIntent{}, errors.New("operator_scope_mismatch")
	}
	if _, err = j.scope(r.Account, r.Generation, r.Chat); err != nil {
		return operatorIntent{}, errors.New("operator_scope_mismatch")
	}
	if i.State == "unknown" {
		var n int
		err = j.db.QueryRow("SELECT EXISTS(SELECT 1 FROM messages WHERE account=? AND generation=? AND chat IN (?,?) AND id=? AND own=1 AND body=?)", i.Account, i.Generation, i.Chat, i.Route, i.SendID, i.Body).Scan(&n)
		if err != nil {
			return i, err
		}
		if n == 1 {
			_, err = j.db.Exec("UPDATE operator_intents SET state='echo_confirmed',reason='exact own ID/chat/body echo; delivery/read unknown' WHERE id=? AND state='unknown'", i.ID)
			if err != nil {
				return i, err
			}
			i, err = readOperator(j.db, i.ID)
		}
	}
	return i, err
}
func operatorError(err error) string {
	if err == nil {
		return ""
	}
	if strings.HasPrefix(err.Error(), "operator_") {
		return err.Error()
	}
	return fmt.Sprint("operator_journal_unavailable")
}

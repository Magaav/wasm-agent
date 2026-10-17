package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"go.mau.fi/whatsmeow/types/events"
)

// No SDK String(), errors, raw nodes, identifiers, QR or network content enters
// this projection. Unknown enum values are collapsed to zero, not echoed.
type Lifecycle struct {
	Event       string `json:"event"`
	At          int64  `json:"at"`
	Generation  int64  `json:"generation"`
	ReasonCode  int    `json:"reason_code"`
	ReasonClass string `json:"reason_class"`
	OnConnect   bool   `json:"on_connect"`
}

func lifecycleReason(reason events.ConnectFailureReason) (int, string) {
	switch reason {
	case 400:
		return 400, "generic"
	case 401:
		return 401, "logged_out"
	case 402:
		return 402, "temporary_ban"
	case 403:
		return 403, "main_device_gone"
	case 405:
		return 405, "client_outdated"
	case 406:
		return 406, "unknown_logout"
	case 409:
		return 409, "bad_user_agent"
	case 413:
		return 413, "cat_expired"
	case 414:
		return 414, "cat_invalid"
	case 415:
		return 415, "not_found"
	case 418:
		return 418, "client_unknown"
	case 500:
		return 500, "internal_server_error"
	case 501:
		return 501, "experimental"
	case 503:
		return 503, "service_unavailable"
	default:
		return 0, "unknown_or_not_applicable"
	}
}
func lifecycleEvent(event string) bool {
	switch event {
	case "pair_success_local", "connected", "disconnected", "logged_out", "connect_failure", "client_outdated", "temporary_ban", "stream_replaced":
		return true
	}
	return false
}
func lifecycleValue(event string, reason events.ConnectFailureReason, onConnect bool, generation int64) Lifecycle {
	code, class := lifecycleReason(reason)
	return Lifecycle{event, time.Now().Unix(), generation, code, class, onConnect}
}
func putLifecycle(tx *sql.Tx, value Lifecycle) error {
	if !lifecycleEvent(value.Event) {
		return errors.New("invalid_lifecycle_event")
	}
	b, err := json.Marshal(value)
	if err != nil {
		return err
	}
	slots := []string{"last_event"}
	if value.Event == "logged_out" {
		slots = append(slots, "last_logout")
	}
	if value.Event == "pair_success_local" {
		slots = append(slots, "last_pair_success")
	}
	for _, slot := range slots {
		if _, err = tx.Exec("INSERT INTO lifecycle VALUES(?,?) ON CONFLICT(slot) DO UPDATE SET value=excluded.value", slot, string(b)); err != nil {
			return err
		}
	}
	_, err = tx.Exec("INSERT INTO events(kind,at,detail) VALUES(?,?,?)", value.Event, value.At, string(b))
	return err
}
func (j *Journal) recordLifecycle(event string, reason events.ConnectFailureReason, onConnect bool) error {
	c, err := j.Config()
	if err != nil {
		return err
	}
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = putLifecycle(tx, lifecycleValue(event, reason, onConnect, c.Generation)); err != nil {
		return err
	}
	return tx.Commit()
}
func saveLifecycleConfig(tx *sql.Tx, c Config, value Lifecycle) error {
	if err := validConfig(c); err != nil {
		return err
	}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	if _, err = tx.Exec("UPDATE config SET value=? WHERE id=1", string(b)); err != nil {
		return err
	}
	return putLifecycle(tx, value)
}
func (j *Journal) loggedOut(reason events.ConnectFailureReason, onConnect bool) error {
	j.identityMu.Lock()
	defer j.identityMu.Unlock()
	// setState already invalidated verified in the old implementation. The added
	// durable latch prevents identity() from resurrecting a not-yet-deleted SDK ID.
	j.setState("needs_pairing")
	j.mu.Lock()
	j.authenticated = false
	j.pairingBlocked = true
	j.mu.Unlock()
	c, err := j.Config()
	if err != nil {
		return err
	}
	c.Requested = false
	c.Generation++
	c.Activated = 0
	c.PairingRequired = true
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = saveLifecycleConfig(tx, c, lifecycleValue("logged_out", reason, onConnect, c.Generation)); err != nil {
		return err
	}
	return tx.Commit()
}

// Called ONLY for the SDK QR-channel success within privateTTY-guarded pair().
// PairSuccess is durable local pairing, not authenticated Connected readiness.
func (a *Adapter) completePair(generation int64) error {
	j := a.journal
	j.identityMu.Lock()
	defer j.identityMu.Unlock()
	c, err := j.Config()
	if err != nil {
		return err
	}
	if c.Generation != generation {
		return errors.New("pairing_generation_changed_reconcile_required")
	}
	if a.client.Store.Deleted || a.client.Store.ID == nil {
		return errors.New("pairing_identity_unproven")
	}
	if a.client.Store.ID.ToNonAD().String() != c.Account {
		return errors.New("paired_account_mismatch")
	}
	if j.hasGap() {
		return errors.New("persistence_gap_requires_reconciliation")
	}
	c.PairingRequired = false
	tx, err := j.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = saveLifecycleConfig(tx, c, lifecycleValue("pair_success_local", 0, false, c.Generation)); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	j.mu.Lock()
	j.pairingBlocked = false
	j.mu.Unlock()
	return a.identityLocked()
}
func (j *Journal) sessionObservation() (map[string]any, error) {
	j.mu.Lock()
	live, verified, authenticated := j.adapterLive, j.verified, j.authenticated
	j.mu.Unlock()
	runtime, identity, auth := "offline_cli", "unobserved", "unobserved"
	if live {
		runtime = "live_adapter"
		identity = "unproven"
		auth = "not_authenticated"
		if verified {
			identity = "matched_local_sdk_store"
		}
		if authenticated {
			auth = "authenticated_event_observed"
		}
	}
	out := map[string]any{"runtime": runtime, "local_identity": identity, "authentication": auth, "coverage": "partial; authentication is not complete history"}
	for _, slot := range []string{"last_event", "last_logout", "last_pair_success"} {
		var raw string
		err := j.db.QueryRow("SELECT value FROM lifecycle WHERE slot=?", slot).Scan(&raw)
		if errors.Is(err, sql.ErrNoRows) {
			out[slot] = nil
			continue
		}
		if err != nil {
			return nil, err
		}
		var v Lifecycle
		if len(raw) > 1024 || json.Unmarshal([]byte(raw), &v) != nil || !lifecycleEvent(v.Event) || v.Generation < 1 || v.At < 1 {
			return nil, errors.New("invalid_lifecycle_record")
		}
		// Recreate allowlisted classification; never echo stored arbitrary strings.
		v.ReasonCode, v.ReasonClass = lifecycleReason(events.ConnectFailureReason(v.ReasonCode))
		out[slot] = v
	}
	return out, nil
}

func (j *Journal) safePairCompletionError(err error) error {
	switch err.Error() {
	case "pairing_generation_changed_reconcile_required", "pairing_identity_unproven", "paired_account_mismatch", "persistence_gap_requires_reconciliation":
		return err
	default:
		j.failPersistence()
		return errors.New("pairing_completion_persistence_failed_reconcile_required")
	}
}

func pairingTerminalError(event string) error {
	switch event {
	case "error":
		return errors.New("pairing_failed_private_terminal_details_not_retained")
	case "err-client-outdated":
		return errors.New("pairing_client_outdated")
	case "err-scanned-without-multidevice":
		return errors.New("pairing_multidevice_required")
	case "err-unexpected-state":
		return errors.New("pairing_unexpected_state_reconcile_required")
	case "timeout":
		return errors.New("pairing_expired")
	default:
		return errors.New("pairing_not_confirmed")
	}
}

// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

type operatorAuthority struct {
	Account    string   `json:"account"`
	Generation int64    `json:"generation"`
	Chats      []string `json:"conversations"`
	Dispatch   string   `json:"-"`
	Approval   string   `json:"-"`
}

// An offline OS-owner command, NOT a model profile flag. No default write grant.
func provisionOperator(j *Journal, c Config, chats []string, approved bool) error {
	if !approved || len(chats) == 0 || len(chats) > 256 {
		return errors.New("operator_explicit_selected_chat_provisioning_required")
	}
	for _, chat := range chats {
		if !canonicalOperatorChat(chat) || (!c.AllChats && !contains(c.Chats, chat)) {
			return errors.New("operator_selected_scope_invalid")
		}
	}
	authority := operatorAuthority{Account: c.Account, Generation: c.Generation, Chats: chats}
	// Refuse partial/existing setup; preserve it for owner reconciliation, never rotate silently.
	for _, name := range []string{"operator-authority.json", "operator-dispatch.token", "operator-approval.token"} {
		if _, err := os.Lstat(filepath.Join(j.dir, name)); !os.IsNotExist(err) {
			return errors.New("operator_existing_or_partial_authority_preserved")
		}
	}
	for _, name := range []string{"operator-dispatch.token", "operator-approval.token"} {
		var b [32]byte
		if _, err := rand.Read(b[:]); err != nil {
			return err
		}
		if err := writeNewSecret(filepath.Join(j.dir, name), []byte(hex.EncodeToString(b[:]))); err != nil {
			return err
		}
	}
	b, _ := json.Marshal(authority)
	return writeNewSecret(filepath.Join(j.dir, "operator-authority.json"), b)
}
func readOperatorSecret(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Size() != 64 || (os.PathSeparator != '\\' && info.Mode().Perm()&0077 != 0) {
		return "", errors.New("operator_private_authority_unavailable")
	}
	b, err := os.ReadFile(path)
	if err != nil || len(b) != 64 {
		return "", errors.New("operator_private_authority_unavailable")
	}
	if _, err = hex.DecodeString(string(b)); err != nil {
		return "", errors.New("operator_private_authority_unavailable")
	}
	return string(b), nil
}
func loadOperatorAuthority(j *Journal) (operatorAuthority, error) {
	var a operatorAuthority
	path := filepath.Join(j.dir, "operator-authority.json")
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return a, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Size() > 65536 || (os.PathSeparator != '\\' && info.Mode().Perm()&0077 != 0) {
		return a, errors.New("operator_private_authority_unavailable")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return a, err
	}
	if json.Unmarshal(b, &a) != nil || a.Account == "" || a.Generation < 1 || len(a.Chats) == 0 || len(a.Chats) > 256 {
		return a, errors.New("operator_authority_invalid")
	}
	a.Dispatch, err = readOperatorSecret(filepath.Join(j.dir, "operator-dispatch.token"))
	if err != nil {
		return a, err
	}
	a.Approval, err = readOperatorSecret(filepath.Join(j.dir, "operator-approval.token"))
	if err != nil {
		return a, err
	}
	readKey, err := readOperatorSecret(filepath.Join(j.dir, "api.token"))
	if err != nil {
		return a, err
	}
	if a.Dispatch == a.Approval || a.Dispatch == readKey || a.Approval == readKey {
		return a, errors.New("operator_credentials_must_be_distinct")
	}
	return a, nil
}
func operatorAPI(j *Journal, read http.Handler, a operatorAuthority, t operatorTransport) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/operator/") {
			read.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		fail := func(code int, reason string) {
			w.WriteHeader(code)
			json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": reason})
		}
		if r.Method != "POST" {
			fail(405, "post_required")
			return
		}
		// Approval is separate from preparation/status/dispatch. Read credentials never match.
		key := a.Dispatch
		if r.URL.Path == "/operator/approve" {
			key = a.Approval
		}
		if key == "" || subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+key)) != 1 {
			fail(403, "operator_capability_required")
			return
		}
		var req operatorRequest
		raw, readErr := io.ReadAll(io.LimitReader(r.Body, 32769))
		if readErr != nil || len(raw) > 32768 || !exactOperatorJSON(raw) {
			fail(400, "operator_invalid_exact_json")
			return
		}
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&req) != nil || decoder.Decode(new(any)) != io.EOF || len(req.Body) > 4096 || len(req.Chat) > 256 || len(req.Reply) > 256 || len(req.Intent) > 64 || len(req.Digest) > 64 {
			fail(400, "operator_invalid_request")
			return
		}
		if req.Account != a.Account || req.Generation != a.Generation || !contains(a.Chats, req.Chat) {
			fail(403, "operator_scope_mismatch")
			return
		}
		if _, err := j.scope(req.Account, req.Generation, req.Chat); err != nil {
			fail(403, "operator_scope_mismatch")
			return
		}
		var i operatorIntent
		var err error
		switch r.URL.Path {
		case "/operator/prepare":
			canonical, route, resolveErr := t.ResolveOperator(r.Context(), req.Chat)
			if resolveErr != nil {
				err = resolveErr
			} else {
				i, err = j.prepareOperator(req, canonical, route, t.NewID)
			}
		case "/operator/approve":
			i, err = j.approveOperator(req)
		case "/operator/send":
			i, err = j.sendOperator(r.Context(), req, t)
		case "/operator/status":
			i, err = j.operatorStatus(req)
		default:
			fail(404, "unknown_operator_operation")
			return
		}
		if err != nil {
			fail(409, operatorError(err))
			return
		}
		// The send/status response reports the receipt state known AT RETURN TIME.
		// It never waits for a network ACK beyond the dispatch call itself and it
		// never upgrades acceptance into delivery.
		delivery, read := operatorReceiptStates(i.DeliveredAt, i.ReadAt)
		encoded, encodeErr := json.Marshal(map[string]any{"ok": true, "intent": i, "draft_visibility": "unsupported", "recipient_identity_basis": "SDK address mapping; person identity is operator responsibility", "recipient_delivery": delivery, "recipient_read": read, "recipient_receipt_basis": "observed only from an exact own message-ID recipient receipt; server acceptance is not delivery and absence stays unknown"})
		if encodeErr != nil || len(encoded)+1 > 65536 {
			fail(503, "operator_response_too_large")
			return
		}
		w.Write(append(encoded, '\n'))
	})
}

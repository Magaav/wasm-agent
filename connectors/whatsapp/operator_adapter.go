// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"errors"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

func operatorEnvelope(i operatorIntent, sender, body string) *waE2E.Message {
	if i.Reply == "" {
		return &waE2E.Message{Conversation: proto.String(i.Body)}
	}
	return &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(i.Body), ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String(i.Reply), Participant: proto.String(sender), QuotedMessage: &waE2E.Message{Conversation: proto.String(body)}}}}
}

// Protocol-only text: never opens a composer, changes a draft or marks a chat read.
// Draft visibility on OTHER devices stays unsupported; no absence is certified.
func (a *Adapter) SendOperator(ctx context.Context, i operatorIntent) (string, error) {
	if ctx.Err() != nil {
		return "", noSubmission("operator_cancelled", false)
	}
	if err := a.identity(); err != nil {
		return "", noSubmission("operator_identity_changed", true)
	}
	if !a.client.IsConnected() || !a.client.IsLoggedIn() {
		return "", noSubmission("operator_not_authenticated", false)
	}
	if err := a.journal.validateOperator(a.journal.db, i); err != nil {
		return "", noSubmission("operator_preparation_changed", true)
	}
	canonical, route, resolveErr := a.ResolveOperator(ctx, i.Chat)
	if resolveErr != nil || canonical != i.Canonical || route != i.Route {
		return "", noSubmission("operator_recipient_mapping_changed", true)
	}
	to, err := types.ParseJID(i.Route)
	if err != nil || !canonicalOperatorChat(i.Route) {
		return "", noSubmission("operator_recipient_invalid", true)
	}
	message := operatorEnvelope(i, "", "")
	if i.Reply != "" {
		var sender, body string
		err = a.journal.db.QueryRow("SELECT CASE WHEN length(CAST(sender AS BLOB))<=256 THEN sender ELSE '' END,CASE WHEN length(CAST(body AS BLOB))<=4096 THEN body ELSE '' END FROM messages WHERE account=? AND generation=? AND chat=? AND id=?", i.Account, i.Generation, i.Chat, i.Reply).Scan(&sender, &body)
		if err != nil {
			return "", noSubmission("operator_quote_unproven", true)
		}
		message = operatorEnvelope(i, sender, body)
	}
	// A final short check immediately before SDK invocation, not a network-held lock.
	if err = a.journal.validateOperator(a.journal.db, i); err != nil {
		return "", noSubmission("operator_preparation_changed", true)
	}
	response, err := a.client.SendMessage(ctx, to, message, whatsmeow.SendRequestExtra{ID: i.SendID, Timeout: 45 * time.Second})
	if err != nil {
		return "", err
	} // Generic SDK errors are ALWAYS uncertain.
	if response.ID != i.SendID || response.Chat.ToNonAD() != to {
		return "", errors.New("operator_ack_mismatch")
	}
	return response.ID, nil
}

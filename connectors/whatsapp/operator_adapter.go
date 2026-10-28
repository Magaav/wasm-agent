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

// operatorEnvelope builds the exact protocol message for one intent.
//
// A mention needs ExtendedTextMessage: ContextInfo does not exist on a bare
// Conversation, so a mention-bearing text is never sent as Conversation even
// when it quotes nothing. A text with no mentions and no quote keeps the
// original shape byte for byte.
func operatorEnvelope(i operatorIntent, sender, body string) *waE2E.Message {
	quoted := i.Reply != ""
	mentions := protocolMentionList(i.Mentions)
	if !quoted && len(mentions) == 0 {
		return &waE2E.Message{Conversation: proto.String(i.Body)}
	}
	contextInfo := &waE2E.ContextInfo{}
	if quoted {
		contextInfo.StanzaID = proto.String(i.Reply)
		contextInfo.Participant = proto.String(sender)
		contextInfo.QuotedMessage = &waE2E.Message{Conversation: proto.String(body)}
	}
	// The mention list is the one frozen with the intent. Nothing is resolved,
	// widened or added at dispatch, and no receipt/read state is touched.
	if len(mentions) != 0 {
		contextInfo.MentionedJID = mentions
	}
	return &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(i.Body), ContextInfo: contextInfo}}
}

// ResolveMentions proves each named person's group participant identity from
// the group's own participant list: one exact group, bounded, never a member
// fan-out, a display name or a caller-supplied alias.
func (a *Adapter) ResolveMentions(ctx context.Context, chat string, requested []string) ([]operatorMention, error) {
	if len(requested) == 0 {
		return nil, nil
	}
	if err := a.identity(); err != nil {
		return nil, errors.New("operator_identity_unproven")
	}
	jid, err := types.ParseJID(chat)
	if err != nil || jid.ToNonAD() != jid || jid.Server != types.GroupServer {
		return nil, errors.New("operator_mention_requires_group")
	}
	bounded, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	info, err := a.client.GetGroupInfo(bounded, jid)
	if err != nil || info == nil || info.JID.ToNonAD() != jid {
		return nil, errors.New("operator_mention_group_unavailable")
	}
	return operatorMentionsFromGroup(chat, info.Participants, requested)
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
	// A mention list without its matching body token would notify someone the
	// message does not name; refuse before the SDK is invoked.
	if err := mentionBodyProven(i); err != nil {
		return "", noSubmission(err.Error(), true)
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

// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

// Mentions for operator-directed protocol text.
//
// A mention is TWO facts that must agree, and this file keeps them together:
//
//	the JID list in ContextInfo.MentionedJID  - which clients notify
//	the "@<user>" token inside the body       - what every reader sees
//
// The token is normalized at PREPARE - before the signature, the intent id, the
// approval digest and the stored body exist - so the bytes an approval binds are
// the bytes that are sent. Nothing rewrites text at dispatch. A requested
// mention whose token is missing from the text is REFUSED, never injected: this
// path may not notify a person the message does not name.
//
// The protocol identity of a mention is the group's own participant identity as
// the pinned SDK reports it (LID in LID-addressed groups, phone number
// otherwise). It is never derived from a display name, from a caller's flag or
// from the shape of an id string. A caller names a person by an exact id it can
// see; the body token is rewritten to that proven identity so a client can
// render the name it already knows for that participant.
//
// Known limit, stated rather than papered over: rendering is the recipient
// client's business. A client that does not resolve the participant identity
// shows the raw token. No live send has been performed to measure that.

import (
	"database/sql"
	"encoding/json"
	"errors"
	"strings"

	"go.mau.fi/whatsmeow/types"
)

// One body carries a bounded set of mentions; more is not a text message
// anybody reads, and it bounds the normalization cost and the intent size.
const operatorMentionLimit = 8

// operatorMention is one mention, frozen: the id the operator named (which the
// body must carry as a token) and the group participant identity the pinned SDK
// proved for it (which is what ContextInfo carries and what the token becomes).
type operatorMention struct {
	Requested string `json:"requested"`
	Protocol  string `json:"protocol"`
}

// mentionTokenUser returns the numeric user part a mention token may name, or
// "" when this id cannot carry one. Mention tokens are numeric on this protocol;
// accepting letters would let display text and identity drift apart.
func mentionTokenUser(jid string) string {
	parts := strings.Split(jid, "@")
	if len(parts) != 2 || parts[0] == "" {
		return ""
	}
	for _, r := range parts[0] {
		if r < '0' || r > '9' {
			return ""
		}
	}
	return parts[0]
}

func mentionToken(jid string) string {
	if user := mentionTokenUser(jid); user != "" {
		return "@" + user
	}
	return ""
}

// mentionBoundary reports whether a token ending at end is a WHOLE token: the
// next byte may not extend it into another number or word, so "@200" is not
// found inside "@2000" or "@200ab".
func mentionBoundary(body string, end int) bool {
	if end >= len(body) {
		return true
	}
	c := body[end]
	return !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z')
}

// scanMentionTokens counts whole-token occurrences of token in body and, when
// replace is not "", returns body with every occurrence replaced. It is a
// scanner rather than a regexp so the exact bytes outside a mention are never
// reinterpreted.
func scanMentionTokens(body, token, replace string) (string, int) {
	if token == "" {
		return body, 0
	}
	var b strings.Builder
	written, pos, n := 0, 0, 0
	for {
		k := strings.Index(body[pos:], token)
		if k < 0 {
			break
		}
		start, end := pos+k, pos+k+len(token)
		if !mentionBoundary(body, end) {
			pos = end
			continue
		}
		if replace != "" {
			b.WriteString(body[written:start])
			b.WriteString(replace)
			written = end
		}
		n++
		pos = end
	}
	if replace == "" {
		return body, n
	}
	b.WriteString(body[written:])
	return b.String(), n
}

// normalizeOperatorMentions rewrites each named person's token to the proven
// participant identity and refuses when a named person is not actually named in
// the text. It is pure: the body it returns is the exact body that will be
// stored, signed, approved and sent.
func normalizeOperatorMentions(body string, mentions []operatorMention) (string, error) {
	if len(mentions) == 0 {
		return body, nil
	}
	out := body
	for _, m := range mentions {
		from, to := mentionToken(m.Requested), mentionToken(m.Protocol)
		if from == "" || to == "" {
			return "", errors.New("operator_mention_identity_invalid")
		}
		var n int
		if out, n = scanMentionTokens(out, from, to); n == 0 {
			// The body may already carry the proven identity (a caller who wrote
			// the group's own token). That still has to be a whole token.
			if _, n = scanMentionTokens(out, to, ""); n == 0 {
				return "", errors.New("operator_mention_token_missing")
			}
		}
	}
	for _, m := range mentions {
		if _, n := scanMentionTokens(out, mentionToken(m.Protocol), ""); n == 0 {
			return "", errors.New("operator_mention_token_missing")
		}
	}
	return out, nil
}

// participantMatches reports whether the group's participant entry is this
// person. Every identity the entry carries counts - primary, phone number and
// LID - because a LID-addressed group reports the LID as primary and the phone
// number separately.
func participantMatches(p types.GroupParticipant, want types.JID) bool {
	for _, c := range []types.JID{p.JID, p.PhoneNumber, p.LID} {
		if !c.IsEmpty() && c.ToNonAD() == want.ToNonAD() {
			return true
		}
	}
	return false
}

// operatorMentionsFromGroup turns exact person ids into proven mention entries.
//
// It is separate from the SDK call so the identity rules are testable without a
// network: what it needs is the group jid and the participant list the pinned
// SDK returned for that exact group.
func operatorMentionsFromGroup(chat string, participants []types.GroupParticipant, requested []string) ([]operatorMention, error) {
	if len(requested) == 0 {
		return nil, nil
	}
	if len(requested) > operatorMentionLimit {
		return nil, errors.New("operator_mention_limit_exceeded")
	}
	// Mentions exist only inside a group. A direct chat's mention list would
	// notify nobody; it is refused rather than silently dropped.
	group, err := types.ParseJID(chat)
	if err != nil || group.Server != types.GroupServer || group.ToNonAD() != group {
		return nil, errors.New("operator_mention_requires_group")
	}
	out := make([]operatorMention, 0, len(requested))
	seenRequested := map[string]bool{}
	seenProtocol := map[string]bool{}
	for _, want := range requested {
		if !canonicalOperatorChat(want) {
			return nil, errors.New("operator_mention_identity_invalid")
		}
		jid, err := types.ParseJID(want)
		if err != nil || jid.ToNonAD() != jid || jid.Server == types.GroupServer || jid.Server == types.BroadcastServer || jid.Server == types.NewsletterServer {
			return nil, errors.New("operator_mention_identity_invalid")
		}
		if mentionToken(want) == "" {
			return nil, errors.New("operator_mention_identity_invalid")
		}
		var match *types.GroupParticipant
		for k := range participants {
			if !participantMatches(participants[k], jid) {
				continue
			}
			if match != nil {
				return nil, errors.New("operator_mention_participant_ambiguous")
			}
			match = &participants[k]
		}
		if match == nil {
			return nil, errors.New("operator_mention_participant_unproven")
		}
		protocol := match.JID.ToNonAD()
		if protocol.IsEmpty() || !canonicalOperatorChat(protocol.String()) || mentionToken(protocol.String()) == "" {
			return nil, errors.New("operator_mention_participant_unproven")
		}
		if seenRequested[want] || seenProtocol[protocol.String()] {
			return nil, errors.New("operator_mention_duplicate")
		}
		seenRequested[want] = true
		seenProtocol[protocol.String()] = true
		out = append(out, operatorMention{Requested: want, Protocol: protocol.String()})
	}
	return out, nil
}

// resolvedOperatorMentions is the invariant between the request the operator
// sent and the resolution the transport proved: same ids, same order, bounded,
// tokenizable. A request that claims mentions without a proven resolution is
// refused here, so no code path can invent one.
func resolvedOperatorMentions(r operatorRequest) ([]operatorMention, error) {
	if len(r.Mentions) == 0 {
		if len(r.resolved) != 0 {
			return nil, errors.New("operator_mention_resolution_mismatch")
		}
		return nil, nil
	}
	if len(r.Mentions) > operatorMentionLimit || len(r.resolved) != len(r.Mentions) {
		return nil, errors.New("operator_mention_resolution_required")
	}
	for k := range r.resolved {
		m := r.resolved[k]
		if m.Requested != r.Mentions[k] {
			return nil, errors.New("operator_mention_resolution_mismatch")
		}
		if !canonicalOperatorChat(m.Requested) || !canonicalOperatorChat(m.Protocol) || mentionToken(m.Requested) == "" || mentionToken(m.Protocol) == "" {
			return nil, errors.New("operator_mention_identity_invalid")
		}
	}
	return r.resolved, nil
}

// requestedMentionList is what an approval must echo: exactly the ids the
// operator named, in the order they named them.
func requestedMentionList(mentions []operatorMention) []string {
	if len(mentions) == 0 {
		return nil
	}
	out := make([]string, 0, len(mentions))
	for _, m := range mentions {
		out = append(out, m.Requested)
	}
	return out
}

// sameOperatorBinding is the approval comparison. It exists because a mention
// list is not comparable with ==; every scalar field and the exact mention
// order are checked, so an approval can never bind a different audience than
// the text it approves.
func sameOperatorBinding(a, b operatorRequest) bool {
	if a.Account != b.Account || a.Generation != b.Generation || a.Chat != b.Chat || a.Body != b.Body || a.Reply != b.Reply {
		return false
	}
	if len(a.Mentions) != len(b.Mentions) {
		return false
	}
	for k := range a.Mentions {
		if a.Mentions[k] != b.Mentions[k] {
			return false
		}
	}
	return true
}

// protocolMentionList is the exact JID list ContextInfo will carry.
func protocolMentionList(mentions []operatorMention) []string {
	if len(mentions) == 0 {
		return nil
	}
	out := make([]string, 0, len(mentions))
	for _, m := range mentions {
		out = append(out, m.Protocol)
	}
	return out
}

// mentionBodyProven re-checks, without any network, that every frozen mention
// identity still has its token in the exact body being sent. It is the last
// cheap guard before the SDK is invoked.
func mentionBodyProven(i operatorIntent) error {
	if len(i.Mentions) > operatorMentionLimit {
		return errors.New("operator_mention_limit_exceeded")
	}
	for _, m := range i.Mentions {
		token := mentionToken(m.Protocol)
		if token == "" || !canonicalOperatorChat(m.Protocol) {
			return errors.New("operator_mention_identity_invalid")
		}
		if _, n := scanMentionTokens(i.Body, token, ""); n == 0 {
			return errors.New("operator_mention_token_unproven")
		}
	}
	return nil
}

// operatorIntentID binds the audience into intent identity. The tag is versioned
// so a mention-less text keeps the id it had before mentions existed (an
// identical repeat stays a duplicate); a mention-bearing text gets its own
// namespace that includes both the named ids and the proven protocol ids.
func operatorIntentID(r operatorRequest, canonical string, mentions []operatorMention) string {
	if len(mentions) == 0 {
		return digest([]any{"operator-text-v1", r.Account, r.Generation, canonical, r.Body, r.Reply})
	}
	return digest([]any{"operator-text-v2", r.Account, r.Generation, canonical, r.Body, r.Reply, requestedMentionList(mentions), protocolMentionList(mentions)})
}

// operatorMentionRecord is the durable form of the mention set: empty for no
// mentions so an old intent reads back exactly as before.
func operatorMentionRecord(mentions []operatorMention) (string, error) {
	if len(mentions) == 0 {
		return "", nil
	}
	b, err := json.Marshal(mentions)
	if err != nil {
		return "", errors.New("operator_mention_record_unavailable")
	}
	if len(b) > 4096 {
		return "", errors.New("operator_mention_record_unavailable")
	}
	return string(b), nil
}

// migrateOperatorMentions is the additive migration for journals created before
// mentions existed. Old rows read back with no mentions, which is honest: an
// intent prepared then notified nobody.
func migrateOperatorMentions(db *sql.DB) error {
	rows, err := db.Query("PRAGMA table_info(operator_intents)")
	if err != nil {
		return err
	}
	found := false
	for rows.Next() {
		var cid, notnull, pk int
		var name, typ string
		var def any
		if err = rows.Scan(&cid, &name, &typ, &notnull, &def, &pk); err != nil {
			rows.Close()
			return err
		}
		if name == "mentions" {
			found = true
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil || found {
		return err
	}
	_, err = db.Exec("ALTER TABLE operator_intents ADD COLUMN mentions TEXT NOT NULL DEFAULT ''")
	return err
}

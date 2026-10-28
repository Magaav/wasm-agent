// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"go.mau.fi/whatsmeow/types"
)

// Synthetic group only: no real group, member or phone number is used here.
const operatorTestGroupChat = "120363111111111111@g.us"

func groupOperatorFixture(t *testing.T) (*Journal, operatorRequest, *operatorFake) {
	t.Helper()
	j := fixture(t)
	j.mu.Lock()
	j.verified = true
	j.authenticated = true
	j.mu.Unlock()
	c, err := j.Config()
	if err != nil {
		t.Fatal(err)
	}
	c.Chats = append(c.Chats, operatorTestGroupChat)
	if err = j.save(c); err != nil {
		t.Fatal(err)
	}
	// The group has to be an observed permitted chat, exactly like a real one.
	if err = j.ingest(Message{ID: "group-source", Chat: operatorTestGroupChat, Sender: "999@lid", Body: "oi", Sent: 100}); err != nil {
		t.Fatal(err)
	}
	return j, operatorRequest{Account: c.Account, Generation: c.Generation, Chat: operatorTestGroupChat, Body: "fala @200, olha isso", Mentions: []string{"200@s.whatsapp.net"}}, &operatorFake{}
}

func withResolvedMentions(t *testing.T, r operatorRequest, f *operatorFake) operatorRequest {
	t.Helper()
	if len(r.Mentions) == 0 {
		r.resolved = nil
		return r
	}
	resolved, err := f.ResolveMentions(context.Background(), r.Chat, r.Mentions)
	if err != nil {
		t.Fatal(err)
	}
	r.resolved = resolved
	return r
}

func preparedGroupOperator(t *testing.T, j *Journal, r operatorRequest, f *operatorFake) operatorIntent {
	t.Helper()
	canonical, route, err := f.ResolveOperator(context.Background(), r.Chat)
	if err != nil {
		t.Fatal(err)
	}
	i, err := j.prepareOperator(r, canonical, route, f.NewID)
	if err != nil {
		t.Fatal(err)
	}
	return i
}

func TestOperatorMentionIdentityFromGroupParticipants(t *testing.T) {
	// A phone-number id is a person; the group's participant list proves the
	// protocol identity a client will render and notify.
	got, err := operatorMentionsFromGroup(operatorTestGroupChat, operatorFakeGroup, []string{"200@s.whatsapp.net"})
	if err != nil || len(got) != 1 || got[0].Requested != "200@s.whatsapp.net" || got[0].Protocol != "999@lid" {
		t.Fatalf("pn mention: %v %v", got, err)
	}
	// The LID names the same participant; it is refused as a duplicate pair,
	// never silently collapsed.
	if _, err = operatorMentionsFromGroup(operatorTestGroupChat, operatorFakeGroup, []string{"999@lid"}); err != nil {
		t.Fatal(err)
	}
	if _, err = operatorMentionsFromGroup(operatorTestGroupChat, operatorFakeGroup, []string{"200@s.whatsapp.net", "999@lid"}); err == nil {
		t.Fatal("same participant mentioned twice accepted")
	}
	if _, err = operatorMentionsFromGroup(operatorTestGroupChat, operatorFakeGroup, []string{"777@s.whatsapp.net"}); err != nil {
		t.Fatal(err)
	}
	ambiguous := append([]types.GroupParticipant{}, operatorFakeGroup...)
	ambiguous = append(ambiguous, types.GroupParticipant{JID: types.NewJID("555", types.HiddenUserServer), PhoneNumber: types.NewJID("200", types.DefaultUserServer)})
	cases := map[string]struct {
		chat      string
		requested []string
	}{
		"direct chat":          {"200@s.whatsapp.net", []string{"200@s.whatsapp.net"}},
		"unproven participant": {operatorTestGroupChat, []string{"123@s.whatsapp.net"}},
		"group id as person":   {operatorTestGroupChat, []string{operatorTestGroupChat}},
		"broadcast id":         {operatorTestGroupChat, []string{"status@broadcast"}},
		"non numeric token":    {operatorTestGroupChat, []string{"acosta@s.whatsapp.net"}},
		"nine mentions":        {operatorTestGroupChat, []string{"1@lid", "2@lid", "3@lid", "4@lid", "5@lid", "6@lid", "7@lid", "8@lid", "9@lid"}},
	}
	for name, tc := range cases {
		if _, err = operatorMentionsFromGroup(tc.chat, operatorFakeGroup, tc.requested); err == nil {
			t.Fatalf("%s accepted", name)
		}
	}
	if _, err = operatorMentionsFromGroup(operatorTestGroupChat, ambiguous, []string{"200@s.whatsapp.net"}); err == nil {
		t.Fatal("ambiguous participant accepted")
	}
}

func TestOperatorMentionTokenNormalization(t *testing.T) {
	mentions := []operatorMention{{Requested: "200@s.whatsapp.net", Protocol: "999@lid"}}
	cases := []struct{ body, want string }{
		{"fala @200, olha isso", "fala @999, olha isso"},
		{"@200 e @200 de novo", "@999 e @999 de novo"},
		{"fala @999", "fala @999"},
		{"sem token @acosta aqui", "sem token @acosta aqui"},
	}
	for _, tc := range cases {
		body, err := normalizeOperatorMentions(tc.body, mentions)
		if tc.body == "sem token @acosta aqui" {
			if err == nil {
				t.Fatal("a mention neither named nor already proven was accepted")
			}
			continue
		}
		if err != nil || body != tc.want {
			t.Fatalf("%q: %q %v", tc.body, body, err)
		}
	}
	for _, body := range []string{"fala @2000", "fala @200abc", "ninguem aqui"} {
		if _, err := normalizeOperatorMentions(body, mentions); err == nil {
			t.Fatalf("%q accepted", body)
		}
	}
	body, err := normalizeOperatorMentions("fala @acosta", nil)
	if err != nil || body != "fala @acosta" {
		t.Fatal(body, err)
	}
	// The dispatch guard: a frozen mention whose token is not in the body is
	// refused before the SDK is invoked.
	if err = mentionBodyProven(operatorIntent{Body: "nada", Mentions: mentions}); err == nil {
		t.Fatal("dispatch accepted an unproven mention")
	}
	if err = mentionBodyProven(operatorIntent{Body: "oi @999", Mentions: mentions}); err != nil {
		t.Fatal(err)
	}
}

func TestOperatorMentionEnvelopeCarriesProvenProtocolJIDs(t *testing.T) {
	i := operatorIntent{Body: "olha @999", Mentions: []operatorMention{{Requested: "200@s.whatsapp.net", Protocol: "999@lid"}}}
	message := operatorEnvelope(i, "", "")
	if message.GetConversation() != "" || message.GetExtendedTextMessage().GetText() != i.Body {
		t.Fatal("mention text is not exact extended text")
	}
	contextInfo := message.GetExtendedTextMessage().GetContextInfo()
	if ids := contextInfo.GetMentionedJID(); len(ids) != 1 || ids[0] != "999@lid" {
		t.Fatalf("mention list: %v", ids)
	}
	if contextInfo.GetStanzaID() != "" || contextInfo.GetQuotedMessage() != nil {
		t.Fatal("a mention invented quote context")
	}
	i.Reply = "source-id"
	quoted := operatorEnvelope(i, "200@s.whatsapp.net", "Olá 💛")
	quotedInfo := quoted.GetExtendedTextMessage().GetContextInfo()
	if quotedInfo.GetStanzaID() != "source-id" || quotedInfo.GetQuotedMessage().GetConversation() != "Olá 💛" || len(quotedInfo.GetMentionedJID()) != 1 {
		t.Fatal("quote and mention did not coexist")
	}
	plain := operatorEnvelope(operatorIntent{Body: "plain"}, "", "")
	if plain.GetConversation() != "plain" || plain.ExtendedTextMessage != nil {
		t.Fatal("a mention-less text changed shape")
	}
}

func TestOperatorMentionPrepareBindsBodyAndAudience(t *testing.T) {
	j, r, f := groupOperatorFixture(t)
	i := preparedGroupOperator(t, j, withResolvedMentions(t, r, f), f)
	if i.Body != operatorSignature+"\nfala @999, olha isso" {
		t.Fatalf("prepared body: %q", i.Body)
	}
	if len(i.Mentions) != 1 || i.Mentions[0].Protocol != "999@lid" || i.Mentions[0].Requested != "200@s.whatsapp.net" {
		t.Fatalf("mentions: %v", i.Mentions)
	}
	// An approval that drops or changes the audience is refused.
	for _, change := range []func(*operatorRequest){func(r *operatorRequest) { r.Mentions = nil }, func(r *operatorRequest) { r.Mentions = []string{"777@s.whatsapp.net"} }} {
		a := approvalRequest(i)
		change(&a)
		if _, err := j.approveOperator(a); err == nil {
			t.Fatal("approval of a different audience accepted")
		}
	}
	// The same text with no mention audience is a different intent.
	plain := r
	plain.resolved = nil
	plain.Mentions = nil
	plainIntent := preparedGroupOperator(t, j, plain, f)
	if plainIntent.ID == i.ID {
		t.Fatal("mention audience did not change intent identity")
	}
	i, err := j.approveOperator(approvalRequest(i))
	if err != nil {
		t.Fatal(err)
	}
	sent, err := j.sendOperator(context.Background(), statusRequest(i), f)
	if err != nil || sent.State != "accepted" || f.calls.Load() != 1 {
		t.Fatal(sent, err)
	}
	if len(sent.Mentions) != 1 || sent.Mentions[0].Protocol != "999@lid" {
		t.Fatalf("durable mentions: %v", sent.Mentions)
	}
	// A named person missing from the text is refused, never injected.
	bad := withResolvedMentions(t, operatorRequest{Account: r.Account, Generation: r.Generation, Chat: r.Chat, Body: "sem ninguem", Mentions: []string{"200@s.whatsapp.net"}}, f)
	if _, err = j.prepareOperator(bad, bad.Chat, bad.Chat, f.NewID); err == nil {
		t.Fatal("unnamed mention accepted")
	}
	// A claimed resolution that the transport never proved is refused.
	claim := operatorRequest{Account: r.Account, Generation: r.Generation, Chat: r.Chat, Body: "fala @200", Mentions: []string{"200@s.whatsapp.net"}}
	if _, err = j.prepareOperator(claim, claim.Chat, claim.Chat, f.NewID); err == nil {
		t.Fatal("unproven mention resolution accepted")
	}
}

func TestOperatorMentionMigrationAddsColumn(t *testing.T) {
	j, r, f := groupOperatorFixture(t)
	if _, err := j.db.Exec("ALTER TABLE operator_intents DROP COLUMN mentions"); err != nil {
		t.Fatal(err)
	}
	if err := installOperator(j.db); err != nil {
		t.Fatal(err)
	}
	rows, err := j.db.Query("PRAGMA table_info(operator_intents)")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for rows.Next() {
		var cid, notnull, pk int
		var name, typ string
		var def any
		if err = rows.Scan(&cid, &name, &typ, &notnull, &def, &pk); err != nil {
			t.Fatal(err)
		}
		if name == "mentions" {
			found = true
		}
	}
	rows.Close()
	if !found {
		t.Fatal("migration did not add the mentions column")
	}
	i := preparedGroupOperator(t, j, withResolvedMentions(t, r, f), f)
	read, err := readOperator(j.db, i.ID)
	if err != nil || len(read.Mentions) != 1 || read.Mentions[0].Requested != "200@s.whatsapp.net" {
		t.Fatal(read.Mentions, err)
	}
}

func TestOperatorMentionHTTPRequiresGroupAndBoundedList(t *testing.T) {
	j, r, f := groupOperatorFixture(t)
	authority := operatorAuthority{Account: r.Account, Generation: r.Generation, Chats: []string{r.Chat, "200@s.whatsapp.net"}, Dispatch: strings.Repeat("d", 64), Approval: strings.Repeat("a", 64)}
	server := httptest.NewServer(operatorAPI(j, api(j, "read-only"), authority, f))
	defer server.Close()
	call := func(path string, body any) (int, map[string]any) {
		t.Helper()
		b, _ := json.Marshal(body)
		request, _ := http.NewRequest("POST", server.URL+path, bytes.NewReader(b))
		request.Header.Set("Authorization", "Bearer "+authority.Dispatch)
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		var out map[string]any
		if err = json.NewDecoder(response.Body).Decode(&out); err != nil {
			t.Fatal(err)
		}
		return response.StatusCode, out
	}
	request := map[string]any{"account": r.Account, "generation": r.Generation, "conversation_id": r.Chat, "body": r.Body, "mentions": r.Mentions}
	code, out := call("/operator/prepare", request)
	if code != 200 {
		t.Fatalf("group prepare: %d %v", code, out)
	}
	prepared, _ := out["intent"].(map[string]any)
	mentions, _ := prepared["mentions"].([]any)
	if len(mentions) != 1 {
		t.Fatalf("prepared mention audience: %v", prepared)
	}
	// A direct chat cannot carry a mention audience.
	code, out = call("/operator/prepare", map[string]any{"account": r.Account, "generation": r.Generation, "conversation_id": "200@s.whatsapp.net", "body": "fala @200", "mentions": []string{"200@s.whatsapp.net"}})
	if code != 409 || out["error"] != "operator_mention_requires_group" {
		t.Fatalf("direct chat mention: %d %v", code, out)
	}
	// Dispatch cannot add an audience after preparation.
	code, _ = call("/operator/send", map[string]any{"account": r.Account, "generation": r.Generation, "conversation_id": r.Chat, "intent_id": strings.Repeat("0", 64), "mentions": r.Mentions})
	if code != 400 {
		t.Fatalf("send with mentions: %d", code)
	}
	code, _ = call("/operator/prepare", map[string]any{"account": r.Account, "generation": r.Generation, "conversation_id": r.Chat, "body": r.Body, "mentions": []string{"1@lid", "2@lid", "3@lid", "4@lid", "5@lid", "6@lid", "7@lid", "8@lid", "9@lid"}})
	if code != 400 {
		t.Fatalf("oversized mention list: %d", code)
	}
}

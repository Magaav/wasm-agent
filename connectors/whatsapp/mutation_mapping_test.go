package main

import (
	"testing"

	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

func historyMutationFixture() *waHistorySync.HistorySync {
	chat := "200@s.whatsapp.net"
	key := func(id string) *waCommon.MessageKey {
		return &waCommon.MessageKey{ID: proto.String(id), RemoteJID: proto.String(chat), FromMe: proto.Bool(false)}
	}
	revoke := &waWeb.WebMessageInfo{Key: key("mutation"), MessageTimestamp: proto.Uint64(112), Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{Type: waE2E.ProtocolMessage_REVOKE.Enum(), Key: key("source")}}}
	original := func(id string) *waWeb.WebMessageInfo {
		return &waWeb.WebMessageInfo{Key: key(id), MessageTimestamp: proto.Uint64(110), Message: &waE2E.Message{AudioMessage: &waE2E.AudioMessage{Mimetype: proto.String("audio/ogg"), FileLength: proto.Uint64(3)}}}
	}
	return &waHistorySync.HistorySync{Conversations: []*waHistorySync.Conversation{{ID: proto.String(chat), Messages: []*waHistorySync.HistorySyncMsg{{Message: revoke}, {Message: original("source")}, {Message: original("unrelated")}}}}}
}
func TestHistoryMutationBeforeSourceUsesActualSDKHeadersBeforeAnyAudioTasks(t *testing.T) {
	old := fixture(t)
	activate(t, old)
	oa := fixtureAdapter(t, old)
	data := historyMutationFixture()
	jid := types.NewJID("200", types.DefaultUserServer)
	// Causal old-order control: the prior callback ingested each item in received order.
	for _, item := range data.Conversations[0].Messages {
		e, err := oa.client.ParseWebMessage(jid, item.Message)
		if err != nil {
			t.Fatal(err)
		}
		if err = old.ingest(mapMessage(e, true)); err != nil {
			t.Fatal(err)
		}
	}
	if count(t, old, "SELECT count(*) FROM chat_holds") != 1 || count(t, old, "SELECT count(*) FROM audio WHERE state='pending' AND reason='source_hold_transcription_only'") != 2 {
		t.Fatal("old sequential order did not reproduce broad hold")
	}
	j := fixture(t)
	activate(t, j)
	a := fixtureAdapter(t, j)
	if !a.persistHistory(historyMutationFixture()) {
		t.Fatal("new history pass")
	}
	if count(t, j, "SELECT count(*) FROM chat_holds") != 0 || count(t, j, "SELECT count(*) FROM source_blocks WHERE id='source'") != 1 || count(t, j, "SELECT count(*) FROM audio WHERE state='pending' AND id='unrelated'") != 1 || count(t, j, "SELECT count(*) FROM audio WHERE state='blocked_source' AND id='source'") != 1 {
		t.Fatal("source fence/independent audio lost")
	}
	if count(t, j, "SELECT count(*) FROM mutation_evidence WHERE author_proof='sdk_history_batch'") != 1 {
		t.Fatal("header provenance missing")
	}
	// Reversing item order must not make an edited source briefly eligible before its fence.
	d := historyMutationFixture()
	d.Conversations[0].Messages[0], d.Conversations[0].Messages[1] = d.Conversations[0].Messages[1], d.Conversations[0].Messages[0]
	other := fixture(t)
	activate(t, other)
	otherAdapter := fixtureAdapter(t, other)
	if !otherAdapter.persistHistory(d) || count(t, other, "SELECT count(*) FROM audio WHERE state='pending' AND id='source'") != 0 {
		t.Fatal("source-first order escaped fence")
	}
}
func TestMutationScopeNormalizationAndAuthenticatedSDKAliasesNotNames(t *testing.T) {
	e := eventAudio("mutation")
	e.Message = &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{Type: waE2E.ProtocolMessage_REVOKE.Enum(), Key: &waCommon.MessageKey{ID: proto.String("source"), RemoteJID: proto.String("200:3@s.whatsapp.net")}}}
	m := mapMessage(e, false)
	if !m.MutationScope || m.ScopeProof != "normalized_remote" {
		t.Fatal(m.ScopeProof)
	}
	e.Info.SenderAlt = types.NewJID("900", types.HiddenUserServer)
	e.Message.ProtocolMessage.Key.RemoteJID = proto.String("900@lid")
	if m = mapMessage(e, false); !m.MutationScope || m.ScopeProof != "sdk_dm_alias" {
		t.Fatal(m.ScopeProof)
	}
	e.Message.ProtocolMessage.Key.RemoteJID = proto.String("901@lid")
	if mapMessage(e, false).MutationScope {
		t.Fatal("unproven remote alias accepted")
	}
	// For own DMs, recipient-alt—not the owner's sender-alt—is the chat alias.
	e.Info.IsFromMe = true
	e.Info.Sender = types.NewJID("100", types.DefaultUserServer)
	e.Info.SenderAlt = types.NewJID("800", types.HiddenUserServer)
	e.Info.RecipientAlt = types.NewJID("900", types.HiddenUserServer)
	e.Message.ProtocolMessage.Key.RemoteJID = proto.String("800@lid")
	if mapMessage(e, false).MutationScope {
		t.Fatal("owner identity became remote chat")
	}
	e.Message.ProtocolMessage.Key.RemoteJID = proto.String("900@lid")
	if !mapMessage(e, false).MutationScope {
		t.Fatal("SDK recipient alias rejected")
	}
}
func TestFutureGroupMutationAuthorAliasStillRequiresSourceProofAndPreservesLegacyHold(t *testing.T) {
	j := wideFixture(t)
	activate(t, j)
	source := audio("source", false, 110)
	source.Chat = "300@g.us"
	source.Sender = "900@lid"
	source.SenderAlt = "200@s.whatsapp.net"
	j.ingest(source)
	m := Message{Chat: source.Chat, Target: source.ID, Sender: "200@s.whatsapp.net", SenderAlt: "900@lid", Mutation: "revoke", MutationScope: true, ScopeProof: "normalized_remote"}
	if source.Sender == m.Sender {
		t.Fatal("old exact-string causal control lost")
	}
	if err := j.ingest(m); err != nil {
		t.Fatal(err)
	}
	if count(t, j, "SELECT count(*) FROM chat_holds") != 0 || count(t, j, "SELECT count(*) FROM mutation_evidence WHERE author_proof='sdk_author_alias'") != 1 {
		t.Fatal("proved SDK author alias held whole group")
	}
	// Existing reason-only historical holds must never acquire a fabricated origin or clear.
	j.db.Exec("INSERT INTO chat_holds VALUES('100@s.whatsapp.net',1,'300@g.us','unproven_mutation_chat_hold')")
	j.ingest(m)
	c, _ := j.Config()
	coverage, err := j.coverage(c)
	if err != nil || coverage["historical_reason_only_holds"] != int64(1) || count(t, j, "SELECT count(*) FROM hold_origins") != 0 {
		t.Fatal(coverage, err)
	}
	missing := m
	missing.Chat = "400@g.us"
	missing.Target = "absent"
	if err = j.ingest(missing); err != nil {
		t.Fatal(err)
	}
	if count(t, j, "SELECT count(*) FROM chat_holds WHERE chat='400@g.us'") != 1 || count(t, j, "SELECT count(*) FROM mutation_evidence WHERE author_proof='target_missing'") != 1 {
		t.Fatal("missing target uncertainty weakened")
	}
	wrong := m
	wrong.Chat = "500@g.us"
	source.Chat = wrong.Chat
	j.ingest(source)
	wrong.Sender = "999@s.whatsapp.net"
	wrong.SenderAlt = ""
	j.ingest(wrong)
	if count(t, j, "SELECT count(*) FROM chat_holds WHERE chat='500@g.us'") != 1 {
		t.Fatal("foreign author accepted")
	}
}
func TestOwnerChatClearRetainsHoldWithAccurateKnownScopeDiagnosis(t *testing.T) {
	j := fixture(t)
	if err := j.ingest(Message{Chat: "200@s.whatsapp.net", Mutation: "owner_chat_clear", OwnerMutation: true}); err != nil {
		t.Fatal(err)
	}
	if count(t, j, "SELECT count(*) FROM chat_holds WHERE reason='owner_chat_clear_hold'") != 1 || count(t, j, "SELECT count(*) FROM mutation_evidence WHERE scope_proof='owner_sdk_event' AND author_proof='owner_chat_operation'") != 1 {
		t.Fatal("owner chat hold lost or mislabelled")
	}
	c, _ := j.Config()
	coverage, err := j.mutationCoverage(c, "")
	if err != nil || coverage["scope_unproven"] != int64(0) {
		t.Fatal(coverage, err)
	}
}

func TestWrappedSDKHistoryEditRetainsExactTargetAndAmbiguousHeadersHold(t *testing.T) {
	j := fixture(t)
	a := fixtureAdapter(t, j)
	original := historyMutationFixture().Conversations[0].Messages[0].Message
	original.Message = &waE2E.Message{DeviceSentMessage: &waE2E.DeviceSentMessage{Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{Type: waE2E.ProtocolMessage_MESSAGE_EDIT.Enum(), Key: &waCommon.MessageKey{ID: proto.String("exact-target"), RemoteJID: proto.String("200@s.whatsapp.net")}, EditedMessage: &waE2E.Message{Conversation: proto.String("synthetic edit")}}}}}
	e, err := a.client.ParseWebMessage(types.NewJID("200", types.DefaultUserServer), original)
	if err != nil {
		t.Fatal(err)
	}
	m := mapMessage(e, true)
	legacyProtocol := e.Message.GetProtocolMessage()
	if legacyProtocol == nil {
		legacyProtocol = e.SourceWebMsg.GetMessage().GetProtocolMessage()
	}
	if e.IsEdit || legacyProtocol != nil {
		t.Fatal("old wrapped-edit loss control did not reproduce")
	}
	if m.Target != "exact-target" || m.Mutation != "edit" || !m.MutationScope {
		t.Fatal("SDK unwrapping lost protocol target", m.Target, m.Mutation)
	}
	c, _ := j.Config()
	s := audio("exact-target", false, 110)
	j.historyAuthor(c, s)
	s.Sender = "999@s.whatsapp.net"
	j.historyAuthor(c, s)
	if err = j.ingest(m); err != nil {
		t.Fatal(err)
	}
	if count(t, j, "SELECT count(*) FROM chat_holds") != 1 || count(t, j, "SELECT count(*) FROM mutation_evidence WHERE author_proof='ambiguous_author'") != 1 {
		t.Fatal("conflicting original headers guessed")
	}
	// Display labels cannot authorize an author or a chat alias.
	e.Info.PushName = "same name"
	e.Info.Sender = types.NewJID("999", types.DefaultUserServer)
	e.Info.SenderAlt = types.EmptyJID
	if authorEquivalent("200@s.whatsapp.net", "", e.Info.Sender.String(), "") {
		t.Fatal("name-based author mapping")
	}
}

// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

type Adapter struct {
	client         *whatsmeow.Client
	store          *sqlstore.Container
	journal        *Journal
	downloadToFile func(context.Context, whatsmeow.DownloadableMessage, whatsmeow.File) error
}

func newAdapter(ctx context.Context, j *Journal) (*Adapter, error) {
	db, err := sql.Open("sqlite", filepath.Join(j.dir, "device-keys.db")+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	store := sqlstore.NewWithDB(db, "sqlite3", nil)
	if err = store.Upgrade(ctx); err != nil {
		db.Close()
		return nil, err
	}
	devices, err := store.GetAllDevices(ctx)
	if err != nil {
		store.Close()
		return nil, err
	}
	if len(devices) > 1 {
		store.Close()
		return nil, errors.New("multiple_device_sessions_refused")
	}
	device, err := store.GetFirstDevice(ctx)
	if err != nil {
		store.Close()
		return nil, err
	}
	a := &Adapter{client: whatsmeow.NewClient(device, nil), store: store, journal: j}
	a.client.EnableAutoReconnect = true
	a.client.ManualHistorySyncDownload = true
	a.client.DisableManualHistorySyncReceipt = true
	a.client.EnableDecryptedEventBuffer = true
	a.client.EmitAppStateEventsOnFullSync = true
	a.client.BackgroundEventCtx = ctx
	a.downloadToFile = a.client.DownloadToFile
	a.client.SetMediaHTTPClient(mediaHTTPClient(mediaDeadline, maxEncryptedAudioBytes))
	j.metadata = &sdkMetadata{a}
	a.client.AddEventHandlerWithSuccessStatus(a.event)
	j.mu.Lock()
	j.adapterLive = true
	j.mu.Unlock()
	return a, nil
}
func (a *Adapter) Close() {
	a.client.Disconnect()
	a.store.Close()
	a.journal.mu.Lock()
	a.journal.authenticated = false
	a.journal.verified = false
	a.journal.adapterLive = false
	a.journal.mu.Unlock()
}
func (a *Adapter) identity() error {
	a.journal.identityMu.Lock()
	defer a.journal.identityMu.Unlock()
	return a.identityLocked()
}
func (a *Adapter) identityLocked() error {
	c, err := a.journal.Config()
	if err != nil {
		return err
	}
	a.journal.mu.Lock()
	blocked := a.journal.pairingBlocked
	a.journal.mu.Unlock()
	if blocked || c.PairingRequired || a.client.Store.Deleted || a.client.Store.ID == nil {
		a.journal.mu.Lock()
		a.journal.verified = false
		a.journal.authenticated = false
		a.journal.mu.Unlock()
		return errors.New("needs_pairing")
	}
	if a.client.Store.ID.ToNonAD().String() != c.Account {
		a.journal.mu.Lock()
		a.journal.verified = false
		a.journal.authenticated = false
		a.journal.mu.Unlock()
		return errors.New("paired_account_mismatch")
	}
	a.journal.mu.Lock()
	a.journal.verified = true
	a.journal.mu.Unlock()
	return nil
}
func (a *Adapter) eventIdentity() bool { return a.identityResult(a.identity()) }
func (a *Adapter) identityResult(err error) bool {
	if err == nil {
		return true
	}
	if err.Error() == "needs_pairing" {
		a.journal.setState("needs_pairing")
		return false
	}
	if err.Error() == "paired_account_mismatch" {
		a.journal.setState("degraded_account_mismatch")
		return false
	}
	return a.journal.failPersistence()
}
func mapMessageHeader(e *events.Message, history bool) Message {
	m := Message{ID: e.Info.ID, Chat: e.Info.Chat.ToNonAD().String(), Sender: e.Info.Sender.ToNonAD().String(), SenderAlt: safeAlternate(e.Info.Sender, e.Info.SenderAlt), Sent: e.Info.Timestamp.Unix(), Own: e.Info.IsFromMe, History: history}
	p := e.Message.GetProtocolMessage()
	if p == nil && e.SourceWebMsg != nil {
		original := (&events.Message{RawMessage: e.SourceWebMsg.GetMessage()}).UnwrapRaw()
		p = original.Message.GetProtocolMessage()
	}
	if e.IsEdit || (p != nil && (p.GetType() == waE2E.ProtocolMessage_REVOKE || p.GetType() == waE2E.ProtocolMessage_MESSAGE_EDIT)) {
		m.Mutation = "edit"
		m.Target = e.Info.ID
		m.MutationScope = true
		m.ScopeProof = "sdk_edit_envelope"
		if p != nil {
			if p.GetType() == waE2E.ProtocolMessage_REVOKE {
				m.Mutation = "revoke"
			}
			m.Target = p.GetKey().GetID()
			m.MutationScope, m.ScopeProof = mutationScope(e, p.GetKey().GetRemoteJID())
		}
		return m
	}
	return m
}
func mapMessage(e *events.Message, history bool) Message {
	m := mapMessageHeader(e, history)
	if m.Mutation != "" {
		return m
	}
	if e.Message == nil {
		m.Unsupported = "empty_message"
		return m
	}
	m.Body = e.Message.GetConversation()
	if m.Body == "" {
		m.Body = e.Message.GetExtendedTextMessage().GetText()
	}
	audio := e.Message.GetAudioMessage()
	m.Audio = audio != nil
	if m.Audio {
		if audio.GetFileLength() > 20*1024*1024 {
			m.Unsupported = "audio_too_large"
		}
		if !strings.HasPrefix(audio.GetMimetype(), "audio/") {
			m.Unsupported = "audio_mimetype_unsupported"
		}
		if audio.GetViewOnce() || e.IsViewOnce {
			m.Unsupported = "view_once"
		}
		if e.IsEphemeral {
			m.Unsupported = "ephemeral_media_not_retained"
		}
		if e.IsEdit {
			m.Unsupported = "edited_audio_unsupported"
		}
		if m.Unsupported == "" {
			m.Raw, _ = proto.Marshal(e.Message)
		}
	}
	image := e.Message.GetImageMessage()
	if image != nil {
		m.MediaKind = "image"
		if m.Body == "" {
			m.Body = image.GetCaption()
		}
		if image.GetFileLength() > 20*1024*1024 {
			m.Unsupported = "image_too_large"
		}
		if mime := image.GetMimetype(); mime != "" && !strings.HasPrefix(mime, "image/") {
			m.Unsupported = "image_mimetype_unsupported"
		}
		if image.GetViewOnce() || e.IsViewOnce {
			m.Unsupported = "view_once"
		}
		if e.IsEphemeral {
			m.Unsupported = "ephemeral_media_not_retained"
		}
		if m.Unsupported == "" {
			m.Raw, _ = proto.Marshal(e.Message)
		}
	}
	if e.IsViewOnce {
		m.Unsupported = "view_once"
	}
	if e.IsEphemeral {
		m.Unsupported = "ephemeral_media_not_retained"
	}
	if !m.Audio && m.MediaKind == "" && m.Body == "" && m.Unsupported == "" {
		m.Unsupported = "unsupported_non_audio_message"
	}
	return m
}
func (a *Adapter) event(evt any) (success bool) {
	j := a.journal
	defer func() {
		if recover() != nil {
			success = j.failPersistence()
		}
	}()
	persist := func(err error) bool {
		if err != nil {
			return j.failPersistence()
		}
		return true
	}
	switch e := evt.(type) {
	case *events.Connected:
		j.identityMu.Lock()
		defer j.identityMu.Unlock()
		if !a.identityResult(a.identityLocked()) {
			return false
		}
		j.mu.Lock()
		j.authenticated = true
		j.mu.Unlock()
		if !persist(j.recordLifecycle("connected", 0, false)) {
			return false
		}
		j.setState("catching_up")
	case *events.OfflineSyncCompleted:
		j.identityMu.Lock()
		defer j.identityMu.Unlock()
		if !a.identityResult(a.identityLocked()) {
			return false
		}
		if !persist(j.event("catch_up", "offline sync signaled; sticky gaps are not cleared")) {
			return false
		}
		j.setState("connected")
	case *events.Disconnected:
		j.mu.Lock()
		j.authenticated = false
		j.mu.Unlock()
		if !persist(j.recordLifecycle("disconnected", 0, false)) {
			return false
		}
		j.setState("reconnecting")
	case *events.LoggedOut:
		return persist(j.loggedOut(e.Reason, e.OnConnect))
	case *events.ConnectFailure:
		j.mu.Lock()
		j.authenticated = false
		j.mu.Unlock()
		return persist(j.recordLifecycle("connect_failure", e.Reason, true))
	case *events.ClientOutdated:
		j.mu.Lock()
		j.authenticated = false
		j.mu.Unlock()
		return persist(j.recordLifecycle("client_outdated", events.ConnectFailureClientOutdated, true))
	case *events.TemporaryBan:
		j.mu.Lock()
		j.authenticated = false
		j.mu.Unlock()
		return persist(j.recordLifecycle("temporary_ban", events.ConnectFailureTempBanned, true))
	case *events.StreamReplaced:
		j.mu.Lock()
		j.authenticated = false
		j.mu.Unlock()
		return persist(j.recordLifecycle("stream_replaced", 0, false))
	case *events.Message:
		if !a.eventIdentity() {
			return false
		}
		if notification := e.Message.GetProtocolMessage().GetHistorySyncNotification(); notification != nil && e.Info.IsFromMe {
			ctx, cancel := context.WithTimeout(a.client.BackgroundEventCtx, 2*time.Minute)
			defer cancel()
			history, err := a.client.DownloadHistorySync(ctx, notification, false)
			if err != nil {
				return j.failPersistence()
			}
			if !a.persistHistory(history) {
				return false
			}
			// Manual history mode: acknowledge only after the complete idempotent batch persisted.
			// Do not delete server history media here. Upstream availability/redelivery is not guaranteed.
			return persist(a.client.SendProtocolMessageReceipt(ctx, e.Info.ID, types.ReceiptTypeHistorySync))
		}
		if !persist(j.ingest(mapMessage(e, false))) {
			return false
		}
		// A group participant's push name is NOT the group's title. Own echoes
		// likewise must never label a remote chat with this account's name.
		if !e.Info.IsFromMe && !e.Info.IsGroup && e.Info.Sender.ToNonAD() == e.Info.Chat.ToNonAD() {
			return persist(j.observeTitle(e.Info.Chat.ToNonAD().String(), e.Info.PushName, "direct_sender_push_name"))
		}
		return true
	case *events.HistorySync:
		if !a.eventIdentity() {
			return false
		}
		return a.persistHistory(e.Data)
	case *events.JoinedGroup:
		if !a.eventIdentity() {
			return false
		}
		return persist(j.observeTitle(e.JID.ToNonAD().String(), e.Name, "group_metadata"))
	case *events.GroupInfo:
		if !a.eventIdentity() {
			return false
		}
		if e.Name != nil {
			return persist(j.observeTitle(e.JID.ToNonAD().String(), e.Name.Name, "group_metadata"))
		}
		return true
	case *events.DeleteForMe:
		if !a.eventIdentity() {
			return false
		}
		return persist(j.ingest(Message{Chat: e.ChatJID.ToNonAD().String(), Target: e.MessageID, Mutation: "owner_delete_for_me", MutationScope: true, OwnerMutation: true}))
	case *events.ClearChat:
		if !a.eventIdentity() {
			return false
		}
		return persist(j.ingest(Message{Chat: e.JID.ToNonAD().String(), Mutation: "owner_chat_clear", OwnerMutation: true}))
	case *events.DeleteChat:
		if !a.eventIdentity() {
			return false
		}
		return persist(j.ingest(Message{Chat: e.JID.ToNonAD().String(), Mutation: "owner_chat_delete", OwnerMutation: true}))
	case *events.Receipt:
		if !a.eventIdentity() {
			return false
		}
		// Bounded local observation of recipient delivery/read for our own exact
		// message IDs. No network wait, no sticky gap and no re-ack claim: the
		// projection result is a durable intent column or a visible counter.
		j.observeReceipt(e)
		return true
	case *events.UndecryptableMessage:
		return persist(j.event("unsupported_message", "undecryptable or unavailable; no lossless claim"))
	}
	return true
}
func (a *Adapter) persistHistory(data *waHistorySync.HistorySync) bool {
	j := a.journal
	if data == nil {
		return j.failPersistence()
	}
	c, err := j.Config()
	if err != nil {
		return j.failPersistence()
	}
	if err := j.event("history_sync", "partial history received"); err != nil {
		return j.failPersistence()
	}
	// Future received batch only: index original SDK author headers BEFORE any
	// mutations or audio tasks. No network calls, no historical replay/reset.
	for phase := 0; phase < 2; phase++ {
		for _, chat := range data.GetConversations() {
			jid, err := types.ParseJID(chat.GetID())
			if err != nil {
				return j.failPersistence()
			}
			for _, item := range chat.GetMessages() {
				e, err := a.client.ParseWebMessage(jid, item.GetMessage())
				if err != nil {
					return j.failPersistence()
				}
				m := mapMessageHeader(e, true)
				m.OriginAccount = c.Account
				m.OriginGeneration = c.Generation
				if phase == 0 && m.Mutation == "" {
					if err = j.historyAuthor(c, m); err != nil {
						return j.failPersistence()
					}
				}
				if phase == 1 && m.Mutation != "" {
					if err = j.ingest(m); err != nil {
						return j.failPersistence()
					}
				}
			}
		}
	}
	for _, chat := range data.GetConversations() {
		jid, err := types.ParseJID(chat.GetID())
		if err != nil {
			return j.failPersistence()
		}
		title := chat.GetDisplayName()
		if title == "" {
			title = chat.GetName()
		}
		if err = j.observeTitle(jid.ToNonAD().String(), title, "history_conversation"); err != nil {
			return j.failPersistence()
		}
		for _, item := range chat.GetMessages() {
			message, err := a.client.ParseWebMessage(jid, item.GetMessage())
			if err != nil {
				return j.failPersistence()
			}
			mapped := mapMessage(message, true)
			if mapped.Mutation != "" {
				continue
			}
			mapped.OriginAccount = c.Account
			mapped.OriginGeneration = c.Generation
			if err = j.ingest(mapped); err != nil {
				return j.failPersistence()
			}
		}
	}
	return true
}
func (a *Adapter) Download(ctx context.Context, m Message) ([]byte, error) {
	if err := a.identity(); err != nil {
		return nil, err
	}
	var p waE2E.Message
	if err := proto.Unmarshal(m.Raw, &p); err != nil {
		return nil, permanentError("media_metadata_unavailable")
	}
	if audio := p.GetAudioMessage(); audio != nil && !audio.GetViewOnce() {
		return boundedMedia(ctx, a.journal.dir, audio, a.downloadToFile, mediaDeadline)
	}
	if image := p.GetImageMessage(); image != nil && !image.GetViewOnce() {
		return boundedMedia(ctx, a.journal.dir, image, a.downloadToFile, mediaDeadline)
	}
	return nil, permanentError("unsupported_media")
}
func (a *Adapter) Ready(expected Config, source Message) error {
	if a.journal.hasGap() {
		return errors.New("persistence_gap_requires_reconciliation")
	}
	if err := a.identity(); err != nil {
		return err
	}
	current, err := a.journal.scope(expected.Account, expected.Generation, source.Chat)
	if err != nil {
		return err
	}
	if blocked, err := blockedSource(a.journal.db, current, source.Chat, source.ID); err != nil {
		return err
	} else if blocked {
		return permanentError("source_mutation_or_chat_hold")
	}
	if source.Sender == "" {
		return permanentError("source_sender_unproven")
	}
	if !current.Requested || !a.client.IsConnected() {
		return errors.New("definite_pre_dispatch_refusal")
	}
	return nil
}
func (a *Adapter) NewID() string { return a.client.GenerateMessageID() }
func (a *Adapter) Send(ctx context.Context, chat, body, id string, source Message) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", noSubmission("cancelled_before_dispatch", false)
	}
	if err := a.identity(); err != nil {
		return "", noSubmission("identity_unproven_before_dispatch", true)
	}
	if !a.client.IsConnected() {
		return "", noSubmission("disconnected_before_dispatch", false)
	}
	c, err := a.journal.scope(source.OriginAccount, source.OriginGeneration, chat)
	if err != nil || !c.Requested {
		return "", noSubmission("scope_changed_before_dispatch", true)
	}
	to, err := types.ParseJID(chat)
	if err != nil {
		return "", noSubmission("chat_unproven_before_dispatch", true)
	}
	quoted := &waE2E.Message{Conversation: proto.String("[audio]")}
	message := &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(body), ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String(source.ID), Participant: proto.String(source.Sender), QuotedMessage: quoted}}}
	if a.journal.hasGap() {
		return "", noSubmission("persistence_gap_before_dispatch", false)
	}
	if blocked, err := blockedSource(a.journal.db, c, chat, source.ID); err != nil {
		return "", noSubmission("source_unproven_before_dispatch", true)
	} else if blocked {
		return "", noSubmission("source_mutation_or_chat_hold", true)
	}
	resp, err := a.client.SendMessage(ctx, to, message, whatsmeow.SendRequestExtra{ID: id, Timeout: 45 * time.Second})
	if err != nil {
		return "", err
	}
	if resp.Chat.ToNonAD() != to.ToNonAD() || resp.ID != id {
		return "", errors.New("send_confirmation_scope_mismatch")
	}
	return resp.ID, nil
}

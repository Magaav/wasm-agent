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
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

type Adapter struct {
	client  *whatsmeow.Client
	store   *sqlstore.Container
	journal *Journal
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
	a.client.AddEventHandler(a.event)
	return a, nil
}
func (a *Adapter) Close() { a.client.Disconnect(); a.store.Close() }
func (a *Adapter) identity() error {
	c, err := a.journal.Config()
	if err != nil {
		return err
	}
	if a.client.Store.ID == nil {
		a.journal.mu.Lock()
		a.journal.verified = false
		a.journal.mu.Unlock()
		return errors.New("needs_pairing")
	}
	if a.client.Store.ID.ToNonAD().String() != c.Account {
		a.journal.mu.Lock()
		a.journal.verified = false
		a.journal.mu.Unlock()
		return errors.New("paired_account_mismatch")
	}
	a.journal.mu.Lock()
	a.journal.verified = true
	a.journal.mu.Unlock()
	return nil
}
func mapMessage(e *events.Message, history bool) Message {
	m := Message{ID: e.Info.ID, Chat: e.Info.Chat.ToNonAD().String(), Sender: e.Info.Sender.ToNonAD().String(), Sent: e.Info.Timestamp.Unix(), Own: e.Info.IsFromMe, History: history}
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
	if e.IsViewOnce {
		m.Unsupported = "view_once"
	}
	if e.IsEphemeral {
		m.Unsupported = "ephemeral_media_not_retained"
	}
	if !m.Audio && m.Body == "" && m.Unsupported == "" {
		m.Unsupported = "unsupported_non_audio_message"
	}
	return m
}
func (a *Adapter) event(evt any) {
	j := a.journal
	switch e := evt.(type) {
	case *events.Connected:
		if a.identity() != nil {
			j.setState("degraded_account_mismatch")
			a.client.Disconnect()
			return
		}
		j.setState("catching_up")
		j.event("connected", "server connection; history completeness unknown")
	case *events.OfflineSyncCompleted:
		j.setState("connected")
		j.event("catch_up", "upstream offline sync completed; not a lossless guarantee")
	case *events.Disconnected:
		j.setState("reconnecting")
	case *events.LoggedOut:
		j.setState("needs_pairing")
		c, err := j.Config()
		if err == nil {
			c.Requested = false
			c.Generation++
			c.Activated = 0
			if err := j.save(c); err != nil {
				j.setState("degraded_logout_persistence")
			}
		}
		j.event("logged_out", "explicit re-pairing required; sends paused")
	case *events.Message:
		if a.identity() != nil {
			return
		}
		if e.IsEdit || e.Message.GetProtocolMessage() != nil {
			j.event("edit_delete_protocol_unsupported", "retained as protocol event; no authoritative state reconstruction")
		}
		if err := j.ingest(mapMessage(e, false)); err != nil {
			j.setState("degraded_persistence")
		}
	case *events.HistorySync:
		if a.identity() != nil {
			return
		}
		j.event("history_sync", "partial history received")
		for _, chat := range e.Data.GetConversations() {
			jid, err := types.ParseJID(chat.GetID())
			if err != nil {
				continue
			}
			for _, item := range chat.GetMessages() {
				message, err := a.client.ParseWebMessage(jid, item.GetMessage())
				if err != nil {
					j.event("history_parse_unsupported", "message could not be mapped")
					continue
				}
				if err = j.ingest(mapMessage(message, true)); err != nil {
					j.setState("degraded_persistence")
				}
			}
		}
	case *events.Receipt:
		j.event("receipt", "received; per-recipient delivery state not reconstructed")
	case *events.UndecryptableMessage:
		j.event("unsupported_message", "undecryptable or unavailable; upstream retry may occur")
	}
}
func (a *Adapter) Download(ctx context.Context, m Message) ([]byte, error) {
	if err := a.identity(); err != nil {
		return nil, err
	}
	var p waE2E.Message
	if err := proto.Unmarshal(m.Raw, &p); err != nil {
		return nil, permanentError("media_metadata_unavailable")
	}
	audio := p.GetAudioMessage()
	if audio == nil || audio.GetViewOnce() {
		return nil, permanentError("unsupported_media")
	}
	if audio.GetFileLength() > 20*1024*1024 {
		return nil, permanentError("audio_too_large")
	}
	return a.client.Download(ctx, audio)
}
func (a *Adapter) Ready(expected Config, source Message) error {
	if err := a.identity(); err != nil {
		return err
	}
	current, err := a.journal.scope(expected.Account, expected.Generation, source.Chat)
	if err != nil {
		return err
	}
	if !current.Requested || !a.client.IsConnected() || source.Sender == "" {
		return errors.New("definite_pre_dispatch_refusal")
	}
	return nil
}
func (a *Adapter) NewID() string { return a.client.GenerateMessageID() }
func (a *Adapter) Send(ctx context.Context, chat, body, id string, source Message) (string, error) {
	if err := a.identity(); err != nil {
		return "", err
	}
	if !a.client.IsConnected() {
		return "", errors.New("not_connected")
	}
	c, err := a.journal.Config()
	if err != nil || !c.Requested || !contains(c.Chats, chat) {
		return "", errors.New("send_not_authorized")
	}
	to, err := types.ParseJID(chat)
	if err != nil {
		return "", err
	}
	quoted := &waE2E.Message{Conversation: proto.String("[audio]")}
	message := &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(body), ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String(source.ID), Participant: proto.String(source.Sender), QuotedMessage: quoted}}}
	resp, err := a.client.SendMessage(ctx, to, message, whatsmeow.SendRequestExtra{ID: id, Timeout: 45 * time.Second})
	if err != nil {
		return "", err
	}
	if resp.Chat.ToNonAD() != to.ToNonAD() || resp.ID != id {
		return "", errors.New("send_confirmation_scope_mismatch")
	}
	return resp.ID, nil
}

// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"errors"

	"go.mau.fi/whatsmeow/types"
)

type operatorLIDStore interface {
	GetPNForLID(context.Context, types.JID) (types.JID, error)
	GetLIDForPN(context.Context, types.JID) (types.JID, error)
}

// Only reciprocal SDK-store mappings count. Names, equal numeric strings and
// caller-supplied aliases are never person/account identity evidence.
func resolveOperatorRecipient(ctx context.Context, chat string, store operatorLIDStore) (string, string, error) {
	fail := func() (string, string, error) { return "", "", errors.New("operator_recipient_alias_mapping_unproven") }
	if !canonicalOperatorChat(chat) {
		return fail()
	}
	jid, err := types.ParseJID(chat)
	if err != nil {
		return fail()
	}
	if jid.Server == types.GroupServer {
		return chat, chat, nil
	}
	var pn, lid types.JID
	if jid.Server == types.DefaultUserServer {
		pn = jid
		lid, err = store.GetLIDForPN(ctx, pn)
	} else {
		lid = jid
		pn, err = store.GetPNForLID(ctx, lid)
	}
	if err != nil || pn.IsEmpty() || lid.IsEmpty() || pn.Server != types.DefaultUserServer || lid.Server != types.HiddenUserServer {
		return fail()
	}
	backPN, e := store.GetPNForLID(ctx, lid)
	if e != nil || backPN != pn {
		return fail()
	}
	backLID, e := store.GetLIDForPN(ctx, pn)
	if e != nil || backLID != lid {
		return fail()
	}
	if !canonicalOperatorChat(pn.String()) || !canonicalOperatorChat(lid.String()) {
		return fail()
	}
	return pn.String(), lid.String(), nil
}
func (a *Adapter) ResolveOperator(ctx context.Context, chat string) (string, string, error) {
	if err := a.identity(); err != nil {
		return "", "", errors.New("operator_identity_unproven")
	}
	// Self is derived only from the authenticated exact device, never chat labels.
	if a.client.Store.ID != nil && chat == a.client.Store.ID.ToNonAD().String() && !a.client.Store.LID.IsEmpty() {
		return chat, a.client.Store.LID.ToNonAD().String(), nil
	}
	return resolveOperatorRecipient(ctx, chat, a.client.Store.LIDs)
}

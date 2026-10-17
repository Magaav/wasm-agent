// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"errors"
	"testing"

	"go.mau.fi/whatsmeow/proto/waAdv"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

func TestOperatorPinnedSDKEnvelopeAndCachedSQLiteMappings(t *testing.T) {
	j := fixture(t)
	a := fixtureAdapter(t, j)
	ctx := context.Background()
	// Synthetic local identity material only, never a real account certificate.
	a.client.Store.Account = &waAdv.ADVSignedDeviceIdentity{Details: []byte{1}, AccountSignature: make([]byte, 64), AccountSignatureKey: make([]byte, 32), DeviceSignature: make([]byte, 64)}
	a.client.Store.LID = types.NewJID("100", types.HiddenUserServer)
	if err := a.client.Store.Save(ctx); err != nil {
		t.Fatal(err)
	}
	pn := types.NewJID("200", types.DefaultUserServer)
	lid := types.NewJID("300", types.HiddenUserServer)
	if err := a.client.Store.LIDs.PutLIDMapping(ctx, lid, pn); err != nil {
		t.Fatal(err)
	}
	canonical, route, err := a.ResolveOperator(ctx, pn.String())
	if err != nil || canonical != pn.String() || route != lid.String() {
		t.Fatal(canonical, route, err)
	}
	i := operatorIntent{Body: "Laura 💛\nexact text", Reply: "source-id", Route: route, Canonical: canonical}
	envelope := operatorEnvelope(i, pn.String(), "Olá 💛")
	contextInfo := envelope.GetExtendedTextMessage().GetContextInfo()
	if envelope.GetExtendedTextMessage().GetText() != i.Body || contextInfo.GetStanzaID() != i.Reply || contextInfo.GetParticipant() != pn.String() || contextInfo.GetQuotedMessage().GetConversation() != "Olá 💛" {
		t.Fatal("quote envelope changed")
	}
	wire, err := proto.Marshal(envelope)
	if err != nil || len(wire) == 0 {
		t.Fatal(err)
	}
	i.Reply = ""
	plain := operatorEnvelope(i, "", "")
	if plain.GetConversation() != i.Body || plain.ExtendedTextMessage != nil || plain.ProtocolMessage != nil {
		t.Fatal("independent text is not exact plain protocol text")
	}
	// Actual owned adapter, unconnected synthetic device: typed proof before SDK.
	_, err = a.SendOperator(ctx, i)
	var noCall notSubmittedError
	if !errors.As(err, &noCall) {
		t.Fatal("unconnected adapter did not prove non-submission", err)
	}
}

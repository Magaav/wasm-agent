// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestOperatorActualCLIHTTPAndSQLiteCapabilities(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Fatal("Node required for operator CLI process fixture")
	}
	j, r, f := operatorFixture(t)
	a := operatorAuthority{Account: r.Account, Generation: r.Generation, Chats: []string{r.Chat}, Dispatch: strings.Repeat("d", 64), Approval: strings.Repeat("a", 64)}
	server := httptest.NewServer(operatorAPI(j, api(j, strings.Repeat("b", 64)), a, f))
	defer server.Close()
	root := t.TempDir()
	dispatch := filepath.Join(root, "dispatch.token")
	approval := filepath.Join(root, "approval.token")
	read := filepath.Join(root, "read.token")
	for p, v := range map[string]string{dispatch: a.Dispatch, approval: a.Approval, read: strings.Repeat("b", 64)} {
		if err = os.WriteFile(p, []byte(v), 0600); err != nil {
			t.Fatal(err)
		}
	}
	config := map[string]any{"kind": "whatsapp-operator-v1", "account": r.Account, "generation": r.Generation, "conversations": a.Chats, "connector_url": server.URL + "/", "dispatch_token_file": dispatch, "approval_token_file": approval}
	configPath := filepath.Join(root, "authority.json")
	requestPath := filepath.Join(root, "request.json")
	script, err := filepath.Abs("../../scripts/whatsapp-operator.mjs")
	if err != nil {
		t.Fatal(err)
	}
	run := func(action string, request any, wantSuccess bool) map[string]any {
		t.Helper()
		b, _ := json.Marshal(config)
		if err := os.WriteFile(configPath, b, 0600); err != nil {
			t.Fatal(err)
		}
		b, _ = json.Marshal(request)
		if err := os.WriteFile(requestPath, b, 0600); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(node, script, action, "--authority-file", configPath, "--request-file", requestPath)
		out, err := cmd.CombinedOutput()
		if (err == nil) != wantSuccess {
			t.Fatalf("CLI %s success=%v expected=%v output=%s", action, err == nil, wantSuccess, out)
		}
		for _, secret := range []string{a.Dispatch, a.Approval, strings.Repeat("b", 64)} {
			if strings.Contains(string(out), secret) {
				t.Fatal("capability value leaked")
			}
		}
		var result map[string]any
		if err := json.Unmarshal(out, &result); err != nil && wantSuccess {
			t.Fatal(err, string(out))
		}
		return result
	}
	prep := map[string]any{"conversation_id": r.Chat, "body": r.Body}
	config["dispatch_token_file"] = read
	run("prepare", prep, false)
	config["dispatch_token_file"] = dispatch
	response := run("prepare", prep, true)
	raw, _ := json.Marshal(response["intent"])
	var i operatorIntent
	if err = json.Unmarshal(raw, &i); err != nil {
		t.Fatal(err)
	}
	approve := map[string]any{"conversation_id": i.Chat, "body": i.Body, "reply_to": i.Reply, "intent_id": i.ID, "approval_digest": i.Digest}
	config["approval_token_file"] = dispatch
	run("approve", approve, false)
	config["approval_token_file"] = approval
	run("approve", approve, true)
	send := map[string]any{"conversation_id": i.Chat, "intent_id": i.ID}
	response = run("send", send, true)
	if response["intent"].(map[string]any)["state"] != "accepted" {
		t.Fatal(response)
	}
	run("send", send, true)
	run("status", send, true)
	if f.calls.Load() != 1 {
		t.Fatal("CLI duplicate external submission")
	}
	prep["approved"] = true
	run("prepare", prep, false)
}
func TestOperatorExactJSONDoesNotNormalizeSurrogates(t *testing.T) {
	for _, b := range []string{`{"body":"💛"}`, `{"body":"\ud83d\udc9b"}`, `{"body":"\\ud800"}`, `{"body":"\ufffd"}`} {
		if !exactOperatorJSON([]byte(b)) {
			t.Fatal("valid JSON text refused", b)
		}
	}
	for _, b := range []string{`{"body":"\ud800"}`, `{"body":"\udc00"}`, `{"body":"\ud800\u0041"}`, "{\"body\":\"\xff\"}"} {
		if exactOperatorJSON([]byte(b)) {
			t.Fatal("inexact JSON accepted")
		}
	}
}

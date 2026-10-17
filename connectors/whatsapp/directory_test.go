package main

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestDirectorySelectedExclusionAndVersionedOversizedTitle(t *testing.T) {
	j := fixture(t)
	c, _ := j.Config()
	if err := j.observeTitle("300@g.us", strings.Repeat("x", 70000), "history_conversation"); err != nil {
		t.Fatal("unapproved metadata should not be retained or poison approved scope", err)
	}
	if count(t, j, "SELECT count(*) FROM chats") != 0 {
		t.Fatal("unapproved title retained")
	}
	if err := j.observeTitle("200@s.whatsapp.net", "Ana", "history_conversation"); err != nil {
		t.Fatal(err)
	}
	title := strings.Repeat("名", 30000) // private damaged/oversized stored-row fixture, not incoming protocol input
	if _, err := j.db.Exec("UPDATE chats SET title=?", title); err != nil {
		t.Fatal(err)
	}
	p, err := j.readPage(c, readRequest{Chat: "200@s.whatsapp.net"}, "list_chats")
	if err != nil {
		t.Fatal(err)
	}
	refs := p["oversized_rows"].([]map[string]any)
	if len(refs) != 1 {
		t.Fatal(p)
	}
	fields := refs[0]["fields"].(map[string]any)
	meta := fields["title"].(map[string]any)
	req := readRequest{Chat: "200@s.whatsapp.net", Resource: "list_chats", Row: refs[0]["row"].(int64), Field: "title", Version: meta["field_version"].(string), Length: 16384}
	var recovered []byte
	for {
		part, err := j.readField(c, req)
		if err != nil {
			t.Fatal(err)
		}
		b, err := base64.StdEncoding.DecodeString(part["data_base64"].(string))
		if err != nil {
			t.Fatal(err)
		}
		recovered = append(recovered, b...)
		if part["complete"] == true {
			break
		}
		req.Offset = part["next_offset"].(int64)
	}
	if string(recovered) != title {
		t.Fatal("title bytes changed")
	}
	if err := j.observeTitle("200@s.whatsapp.net", "New Ana", "direct_sender_push_name"); err != nil {
		t.Fatal(err)
	}
	if _, err := j.readField(c, req); err == nil || err.Error() != "field_version_changed_restart" {
		t.Fatal("stale title version accepted", err)
	}
}

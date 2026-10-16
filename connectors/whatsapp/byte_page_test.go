package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBytePageIncrementalCapAndLastDeliveredCursor(t *testing.T) {
	j := fixture(t)
	body := strings.Repeat("x", 40000)
	for i := 0; i < 140; i++ {
		if err := j.ingest(Message{ID: strings.Repeat("m", i+1), Chat: "200@s.whatsapp.net", Body: body, Sent: 1}); err != nil {
			t.Fatal(err)
		}
	}
	c, _ := j.Config()
	r := readRequest{Chat: "200@s.whatsapp.net", Limit: 140}
	seen := map[int64]bool{}
	for pageNo := 0; pageNo < 10; pageNo++ {
		data, err := j.readPage(c, r, "read_snapshot")
		if err != nil {
			t.Fatal(err)
		}
		encoded, err := marshalBytePage(data)
		if err != nil || len(encoded) > pageByteLimit || data["encoded_bytes"] != len(encoded) {
			t.Fatal("encoded page over bound", err)
		}
		for _, m := range data["messages"].([]Message) {
			if seen[m.Cursor] || m.Body != body {
				t.Fatal("lost/duplicate/clipped row")
			}
			seen[m.Cursor] = true
		}
		if data["truncated"] == false {
			break
		}
		if data["byte_truncated"] != true || data["rows_delivered"].(int) == 0 {
			t.Fatal("byte continuation missing")
		}
		order := data["order"].([]map[string]any)
		next := data["next_before"].(int64)
		if next != order[len(order)-1]["cursor"].(int64) {
			t.Fatal("cursor advanced over omitted row")
		}
		r.Before = next
	}
	if len(seen) != 140 {
		t.Fatal("pagination lost source rows", len(seen))
	}
}
func TestOversizedExactFieldsUTF8EscapesAndVersionRefusal(t *testing.T) {
	j := fixture(t)
	body := strings.Repeat("á🗣<\\\"\x00", 20000)
	if err := j.ingest(Message{ID: "large", Chat: "200@s.whatsapp.net", Body: body, Sent: 1}); err != nil {
		t.Fatal(err)
	}
	c, _ := j.Config()
	data, err := j.readPage(c, readRequest{Chat: "200@s.whatsapp.net", Limit: 1}, "read_snapshot")
	if err != nil {
		t.Fatal(err)
	}
	overs := data["oversized_rows"].([]map[string]any)
	if len(overs) != 1 || len(data["messages"].([]Message)) != 0 || data["inline_complete"] != false {
		t.Fatal("oversize lost or silently clipped")
	}
	fields := overs[0]["fields"].(map[string]any)
	meta := fields["body"].(map[string]any)
	req := readRequest{Chat: "200@s.whatsapp.net", Resource: "read_snapshot", Row: overs[0]["row"].(int64), Field: "body", Version: meta["field_version"].(string), Length: fieldChunkBytes}
	var reconstructed bytes.Buffer
	for {
		chunk, err := j.readField(c, req)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := base64.StdEncoding.DecodeString(chunk["data_base64"].(string))
		if err != nil || len(raw) > fieldChunkBytes {
			t.Fatal("bad bounded chunk")
		}
		reconstructed.Write(raw)
		next := chunk["next_offset"].(int64)
		if next != req.Offset+int64(len(raw)) {
			t.Fatal("field offset skipped bytes")
		}
		if chunk["complete"] == true {
			break
		}
		if next <= req.Offset {
			t.Fatal("no chunk progress")
		}
		req.Offset = next
	}
	if reconstructed.String() != body {
		t.Fatal("UTF8/escaped source bytes changed")
	}
	j.db.Exec("UPDATE messages SET body='changed' WHERE id='large'")
	req.Offset = 0
	if _, err = j.readField(c, req); err == nil {
		t.Fatal("changed field version accepted")
	}
	req.Chat = "300@s.whatsapp.net"
	if _, err = j.readField(c, req); err == nil {
		t.Fatal("foreign scope accepted")
	}
}
func TestPageNoProgressAndLateMetadataRefusal(t *testing.T) {
	j := fixture(t)
	j.ingest(Message{ID: "m", Chat: "200@s.whatsapp.net", Body: "source", Sent: 1})
	c, _ := j.Config()
	if data, err := j.readPageBudget(c, readRequest{Limit: 1}, "read_snapshot", pageEnvelopeReserve+1); data != nil || !errors.Is(err, errPageNoProgress) {
		t.Fatal("no-progress silently accepted")
	}
	j.setState(strings.Repeat("late metadata", 1000))
	reqBody, _ := json.Marshal(map[string]any{"account": c.Account, "generation": 1, "conversation_id": "200@s.whatsapp.net"})
	req := httptest.NewRequest("POST", "/read_snapshot", bytes.NewReader(reqBody))
	req.Header.Set("Authorization", "Bearer fixture")
	response := httptest.NewRecorder()
	api(j, "fixture").ServeHTTP(response, req)
	if response.Code != 503 || !strings.Contains(response.Body.String(), "page_no_progress") || response.Body.Len() > 1024 {
		t.Fatal("late metadata escaped budget/refusal", response.Code)
	}
}
func TestMalformedScalarUsesBoundedDescriptorAndHonestFreshness(t *testing.T) {
	j := fixture(t)
	j.ingest(Message{ID: "scalar", Chat: "200@s.whatsapp.net", Body: "fixture", Sent: 1})
	value := strings.Repeat("not-integer", 10000)
	j.db.Exec("UPDATE messages SET observed=? WHERE id='scalar'", value)
	c, _ := j.Config()
	data, err := j.readPage(c, readRequest{Limit: 1}, "read_snapshot")
	if err != nil {
		t.Fatal(err)
	}
	if data["source_state"].(map[string]any)["observation_metadata_valid"] != false {
		t.Fatal("invalid scalar falsely certified freshness")
	}
	d := data["oversized_rows"].([]map[string]any)[0]
	f := d["fields"].(map[string]any)["observed_at"].(map[string]any)
	part, err := j.readField(c, readRequest{Resource: "read_snapshot", Row: d["row"].(int64), Field: "observed_at", Version: f["field_version"].(string), Length: 16})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := base64.StdEncoding.DecodeString(part["data_base64"].(string))
	if string(raw) != value[:16] {
		t.Fatal("non-inline scalar lost")
	}
}
func TestChatPostingAndTranscriptOversizeAreRetrievable(t *testing.T) {
	j := fixture(t)
	j.ingest(audio("transcript", false, 110))
	large := strings.Repeat("\\\"字", 50000)
	j.db.Exec("UPDATE audio SET transcript=? WHERE id='transcript'", large)
	j.db.Exec("INSERT INTO chat_holds VALUES('100@s.whatsapp.net',1,'200@s.whatsapp.net',?)", large)
	j.db.Exec("INSERT INTO outbox(account,generation,chat,source,part,body,send_id,state,ack) VALUES('100@s.whatsapp.net',1,'200@s.whatsapp.net','transcript',0,'fixture','id','unknown',?)", large)
	c, _ := j.Config()
	for _, kind := range []string{"read_snapshot", "list_chats", "posting_status"} {
		data, err := j.readPage(c, readRequest{Limit: 10}, kind)
		if err != nil {
			t.Fatal(err)
		}
		encoded, err := marshalBytePage(data)
		if err != nil || len(encoded) > pageByteLimit || len(data["oversized_rows"].([]map[string]any)) != 1 {
			t.Fatal("non-message page lost bound", kind, err)
		}
	}
}

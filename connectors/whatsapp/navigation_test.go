package main

import (
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
	"strings"
	"testing"
	"time"
)

func TestNavigationNamesDuplicatesSearchTimeAndScope(t *testing.T) {
	j := wideFixture(t)
	c, _ := j.Config()
	for i, chat := range []string{"200@s.whatsapp.net", "300@g.us", "400@lid"} {
		if err := j.observeTitle(chat, "Ana", "history_conversation"); err != nil {
			t.Fatal(err)
		}
		m := audio(chat, false, 110+int64(i))
		m.Chat = chat
		m.Body = "literal %_ Budget"
		j.ingest(m)
	}
	p, err := j.readPage(c, readRequest{AccountWide: true, Query: "ana", Limit: 2}, "list_chats")
	if err != nil || p["rows_delivered"] != 2 || p["next_before"] == int64(0) {
		t.Fatal(p, err)
	}
	p2, err := j.readPage(c, readRequest{AccountWide: true, Query: "ana", Before: p["next_before"].(int64), Limit: 2}, "list_chats")
	if err != nil || p2["rows_delivered"] != 1 {
		t.Fatal(p2, err)
	}
	p, err = j.readPage(c, readRequest{Chat: "300@g.us", Query: "%_", SentSince: 111, Until: 111}, "read_snapshot")
	if err != nil || len(p["messages"].([]Message)) != 1 {
		t.Fatal(p, err)
	}
	j.db.Exec("UPDATE audio SET transcript='falamos orçamento',state='ready' WHERE chat='300@g.us'")
	p, err = j.readPage(c, readRequest{Chat: "300@g.us", Query: "orçamento"}, "read_snapshot")
	if err != nil || len(p["messages"].([]Message)) != 1 {
		t.Fatal(p, err)
	}
	p, err = j.readPage(c, readRequest{Chat: "200@s.whatsapp.net", Query: "orçamento"}, "read_snapshot")
	if err != nil || len(p["messages"].([]Message)) != 0 {
		t.Fatal("search leaked", p, err)
	}
	if _, err = j.readPage(c, readRequest{Chat: "200@s.whatsapp.net", Query: strings.Repeat("x", 257)}, "read_snapshot"); err == nil {
		t.Fatal("unbounded query")
	}
	// Oversized name recovery uses the SAME owning chat version as ordinary fields.
	j.observeTitle("300@g.us", strings.Repeat("名", 22000), "group_metadata") // refused >64KiB
	title := strings.Repeat("\x01", 65536)
	if err = j.observeTitle("300@g.us", title, "group_metadata"); err != nil {
		t.Fatal(err)
	}
	// Escaping is bounded by the existing row/page constructor, not raw string length.
	p, err = j.readPage(c, readRequest{Chat: "300@g.us", Limit: 1}, "list_chats")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = marshalBytePage(p); err != nil {
		t.Fatal(err)
	}
}
func TestProtocolTitleSourcesAndNoParticipantOrOwnRelabel(t *testing.T) {
	j := wideFixture(t)
	a := fixtureAdapter(t, j)
	if !a.persistHistory(&waHistorySync.HistorySync{Conversations: []*waHistorySync.Conversation{{ID: proto.String("300@g.us"), Name: proto.String("Family")}}}) {
		t.Fatal("history title")
	}
	if !a.event(&events.GroupInfo{JID: types.NewJID("300", types.GroupServer), Name: &types.GroupName{Name: "Renamed"}, Timestamp: time.Now()}) {
		t.Fatal("group title")
	}
	e := eventAudio("direct")
	e.Info.PushName = "Ana"
	if !a.event(e) {
		t.Fatal("push name")
	}
	e.Info.IsFromMe = true
	e.Info.PushName = "Self"
	e.Info.ID = "own"
	if !a.event(e) {
		t.Fatal("own")
	}
	e.Info.IsFromMe = false
	e.Info.IsGroup = true
	e.Info.Chat = types.NewJID("300", types.GroupServer)
	e.Info.ID = "participant"
	e.Info.PushName = "Participant"
	if !a.event(e) {
		t.Fatal("group")
	}
	if err := j.observeTitle("300@g.us", "Old history label", "history_conversation"); err != nil {
		t.Fatal(err)
	}
	c, _ := j.Config()
	p, err := j.readPage(c, readRequest{AccountWide: true}, "list_chats")
	if err != nil {
		t.Fatal(err)
	}
	titles := map[string]string{}
	for _, row := range p["conversations"].([]map[string]any) {
		titles[row["id"].(string)] = row["title"].(string)
	}
	if titles["200@s.whatsapp.net"] != "Ana" || titles["300@g.us"] != "Renamed" {
		t.Fatal(titles)
	}
}

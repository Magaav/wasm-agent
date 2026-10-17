package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types"
)

type metadataFixture struct {
	check func(context.Context, Config) error
	name  func(context.Context, string) (string, string, error)
	calls []string
}

func (m *metadataFixture) Check(ctx context.Context, c Config) error {
	if m.check != nil {
		return m.check(ctx, c)
	}
	return nil
}
func (m *metadataFixture) Name(ctx context.Context, id string) (string, string, error) {
	m.calls = append(m.calls, id)
	return m.name(ctx, id)
}
func readyMetadata(t *testing.T, j *Journal) *metadataFixture {
	t.Helper()
	j.mu.Lock()
	j.verified = true
	j.authenticated = true
	j.mu.Unlock()
	f := &metadataFixture{name: func(context.Context, string) (string, string, error) { return "Ana", "sdk_contact_full_name", nil }}
	j.metadata = f
	return f
}
func TestMetadataRefreshScopedBoundedNamesAndLivePriority(t *testing.T) {
	j := wideFixture(t)
	f := readyMetadata(t, j)
	for _, id := range []string{"200@s.whatsapp.net", "300@lid", "400@g.us", "401@g.us", "402@g.us", "403@g.us"} {
		if err := j.observeTitle(id, "History", "history_conversation"); err != nil {
			t.Fatal(err)
		}
	}
	j.observeTitle("200@s.whatsapp.net", "Live", "direct_sender_push_name")
	c, _ := j.Config()
	before, _ := j.readPage(c, readRequest{AccountWide: true, Query: "Ana"}, "list_chats")
	if before["rows_delivered"] != 0 {
		t.Fatal("old opportunistic-name control lost")
	}
	r := readRequest{Conversations: []string{"200@s.whatsapp.net", "300@lid"}, Limit: 2}
	result, err := j.refreshNames(context.Background(), c, r)
	if err != nil || result.Checked != 2 || result.Updated != 2 || result.Preserved != 1 {
		t.Fatal(result, err)
	}
	if len(f.calls) != 2 {
		t.Fatal("unrelated metadata queried", f.calls)
	}
	p, err := j.readPage(c, readRequest{AccountWide: true, Query: "Ana"}, "list_chats")
	live, _ := j.readPage(c, readRequest{Chat: "200@s.whatsapp.net"}, "list_chats")
	row := live["conversations"].([]map[string]any)[0]
	if row["title"] != "Live" || row["metadata_title"] != "Ana" {
		t.Fatal("saved name inaccessible or live display overwritten", row)
	}
	if err != nil || p["rows_delivered"] != 2 {
		t.Fatal(p, err)
	}
	result, err = j.refreshNames(context.Background(), c, readRequest{AccountWide: true, Limit: 32})
	if err != nil || result.DeferredGroups != 1 || result.Checked != 5 {
		t.Fatal(result, err)
	}
	if _, err = j.refreshNames(context.Background(), c, readRequest{AccountWide: true, Query: "Ana", Limit: 1}); err == nil {
		t.Fatal("filtered refresh accepted")
	}
	if _, err = j.refreshNames(context.Background(), c, readRequest{AccountWide: true, Limit: 33}); err == nil {
		t.Fatal("refresh row cap ignored")
	}
	j.namesMu.Lock()
	result, err = j.refreshNames(context.Background(), c, r)
	j.namesMu.Unlock()
	if err != nil || result.Status != "busy" {
		t.Fatal(result, err)
	}
}
func TestMetadataLookupDoesNotHoldJournalOrIdentityLocksAndPreservesNewLiveVersion(t *testing.T) {
	j := fixture(t)
	f := readyMetadata(t, j)
	c, _ := j.Config()
	j.observeTitle("200@s.whatsapp.net", "History", "history_conversation")
	entered, release := make(chan struct{}), make(chan struct{})
	f.name = func(ctx context.Context, id string) (string, string, error) {
		close(entered)
		select {
		case <-release:
			return "Stale cached label", "sdk_contact_full_name", nil
		case <-ctx.Done():
			return "", "", ctx.Err()
		}
	}
	done := make(chan NameRefresh, 1)
	go func() {
		r, _ := j.refreshNames(context.Background(), c, readRequest{Chat: "200@s.whatsapp.net", Limit: 1})
		done <- r
	}()
	<-entered
	// Causal critical-path proof while the metadata query is blocked.
	work := make(chan error, 1)
	go func() {
		if err := j.ingest(audio("independent", false, 110)); err != nil {
			work <- err
			return
		}
		j.identityMu.Lock()
		j.identityMu.Unlock()
		work <- j.observeTitle("200@s.whatsapp.net", "Fresh live", "direct_sender_push_name")
	}()
	select {
	case err := <-work:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("metadata blocked ingestion or identity lock")
	}
	close(release)
	result := <-done
	if result.Updated != 0 || result.Preserved != 1 {
		t.Fatal(result)
	}
	p, _ := j.readPage(c, readRequest{Chat: "200@s.whatsapp.net"}, "list_chats")
	if p["conversations"].([]map[string]any)[0]["title"] != "Fresh live" {
		t.Fatal(p)
	}
}
func TestMetadataGenerationCancellationFailureAndExactFieldVersion(t *testing.T) {
	j := fixture(t)
	f := readyMetadata(t, j)
	c, _ := j.Config()
	j.observeTitle("200@s.whatsapp.net", "History", "history_conversation")
	f.name = func(context.Context, string) (string, string, error) {
		next := c
		next.Generation++
		j.save(next)
		return "Wrong generation", "sdk_contact_full_name", nil
	}
	result, err := j.refreshNames(context.Background(), c, readRequest{Chat: "200@s.whatsapp.net", Limit: 1})
	if err != nil || result.Status != "authentication_changed" || result.Updated != 0 {
		t.Fatal(result, err)
	}
	j.save(c)
	ctx, cancel := context.WithCancel(context.Background())
	f.name = func(context.Context, string) (string, string, error) {
		cancel()
		return "cancelled", "sdk_contact_full_name", nil
	}
	result, err = j.refreshNames(ctx, c, readRequest{Chat: "200@s.whatsapp.net", Limit: 1})
	if err != nil || result.Status != "cancelled" || result.Updated != 0 {
		t.Fatal(result, err)
	}
	f.name = func(context.Context, string) (string, string, error) {
		return "", "", errors.New("PRIVATE_RAW_ERROR_MUST_NOT_ESCAPE")
	}
	result, err = j.refreshNames(context.Background(), c, readRequest{Chat: "200@s.whatsapp.net", Limit: 1})
	if err != nil || result.Status != "partial_failures" || result.Failed != 1 || j.hasGap() {
		t.Fatal(result, err)
	}
	data, _ := j.status()
	b, _ := json.Marshal(data)
	if strings.Contains(string(b), "PRIVATE_RAW_ERROR") {
		t.Fatal("raw error escaped")
	}
	j.db.Exec("UPDATE chats SET title=?", strings.Repeat("x", 70000))
	page, _ := j.readPage(c, readRequest{Chat: "200@s.whatsapp.net"}, "list_chats")
	ref := page["oversized_rows"].([]map[string]any)[0]
	version := ref["fields"].(map[string]any)["title"].(map[string]any)["field_version"].(string)
	f.name = func(context.Context, string) (string, string, error) {
		return "Recovered", "sdk_contact_full_name", nil
	}
	result, err = j.refreshNames(context.Background(), c, readRequest{Chat: "200@s.whatsapp.net", Limit: 1})
	if err != nil || result.Updated != 1 {
		t.Fatal(result, err)
	}
	if _, err = j.readField(c, readRequest{Chat: "200@s.whatsapp.net", Resource: "list_chats", Row: ref["row"].(int64), Field: "title", Version: version, Length: 16}); err == nil || err.Error() != "field_version_changed_restart" {
		t.Fatal("stale oversized version accepted", err)
	}
}

type contactsFixture struct {
	store.ContactStore
	data  map[string]types.ContactInfo
	calls []string
}

func (f *contactsFixture) GetContact(ctx context.Context, j types.JID) (types.ContactInfo, error) {
	f.calls = append(f.calls, j.String())
	return f.data[j.String()], nil
}

type lidsFixture struct {
	store.LIDStore
	pn, lid types.JID
}

func (f *lidsFixture) GetPNForLID(context.Context, types.JID) (types.JID, error) { return f.pn, nil }
func (f *lidsFixture) GetLIDForPN(context.Context, types.JID) (types.JID, error) { return f.lid, nil }
func TestSupportedSDKContactAndReciprocalMapProjectionDoesNotInventConversations(t *testing.T) {
	j := fixture(t)
	a := fixtureAdapter(t, j)
	contacts := &contactsFixture{data: map[string]types.ContactInfo{"200@s.whatsapp.net": {Found: true, FullName: "Saved contact"}, "500@s.whatsapp.net": {Found: true, FullName: "Unrelated"}}}
	lid := types.NewJID("900", types.HiddenUserServer)
	maps := &lidsFixture{pn: types.NewJID("200", types.DefaultUserServer), lid: lid}
	a.client.Store.Contacts = contacts
	a.client.Store.LIDs = maps
	reader := &sdkMetadata{a}
	title, source, err := reader.Name(context.Background(), lid.String())
	if err != nil || title != "Saved contact" || source != "sdk_contact_full_name_via_sdk_lid_map" {
		t.Fatal(title, source, err)
	}
	if count(t, j, "SELECT count(*) FROM chats") != 0 {
		t.Fatal("contact became fabricated chat")
	}
	for _, call := range contacts.calls {
		if strings.Contains(call, "500") {
			t.Fatal("unrelated contact read")
		}
	}
	maps.lid = types.NewJID("901", types.HiddenUserServer)
	if _, _, err = reader.Name(context.Background(), lid.String()); err == nil {
		t.Fatal("nonreciprocal alias accepted")
	}
	if name, _ := contactLabel(types.ContactInfo{Found: true, RedactedPhone: "redacted"}); name != "" {
		t.Fatal("redacted phone became name")
	}
}
func TestMetadataInvalidStoredIDsAndCacheWriteFailureStayBoundedAndSeparate(t *testing.T) {
	j := wideFixture(t)
	f := readyMetadata(t, j)
	c, _ := j.Config()
	j.observeTitle("200@s.whatsapp.net", "History", "history_conversation")
	j.db.Exec("INSERT INTO chats(account,generation,chat) VALUES(?,?,?)", c.Account, c.Generation, strings.Repeat("x", 70000))
	report, err := j.refreshNames(context.Background(), c, readRequest{AccountWide: true, Limit: 1})
	if err != nil || report.Failed != 1 || len(f.calls) != 0 {
		t.Fatal(report, err)
	}
	j.db.Exec("CREATE TRIGGER refuse_name_update BEFORE UPDATE ON chats BEGIN SELECT RAISE(ABORT,'PRIVATE_CACHE_ERROR'); END")
	report, err = j.refreshNames(context.Background(), c, readRequest{Chat: "200@s.whatsapp.net", Limit: 1})
	if err != nil || report.Status != "cache_write_failed" || report.Failed != 1 || j.hasGap() {
		t.Fatal(report, err)
	}
	status, err := j.status()
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(status)
	if bytes.Contains(encoded, []byte("PRIVATE_CACHE_ERROR")) {
		t.Fatal("private error escaped")
	}
}

func TestMetadataAPIRechecksNarrowedServiceScopeAfterLookup(t *testing.T) {
	j := wideFixture(t)
	f := readyMetadata(t, j)
	c, _ := j.Config()
	j.observeTitle("200@s.whatsapp.net", "A", "history_conversation")
	j.observeTitle("300@s.whatsapp.net", "B", "history_conversation")
	f.name = func(context.Context, string) (string, string, error) {
		narrow := c
		narrow.AllChats = false
		narrow.Chats = []string{"200@s.whatsapp.net"}
		j.save(narrow)
		return "Must not publish", "sdk_contact_full_name", nil
	}
	body, _ := json.Marshal(readRequest{Account: c.Account, Generation: c.Generation, AccountWide: true, RefreshNames: true, Limit: 2})
	req := httptest.NewRequest("POST", "/list_chats", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer synthetic")
	out := httptest.NewRecorder()
	api(j, "synthetic").ServeHTTP(out, req)
	if out.Code != 403 || !bytes.Contains(out.Body.Bytes(), []byte("read_scope_not_approved")) {
		t.Fatal(out.Code, out.Body.String())
	}
}

func TestMetadataRefreshActualAPIKeepsScopedOrderedBytePage(t *testing.T) {
	j := wideFixture(t)
	f := readyMetadata(t, j)
	j.observeTitle("200@s.whatsapp.net", "History", "history_conversation")
	j.observeTitle("300@s.whatsapp.net", "Other", "history_conversation")
	c, _ := j.Config()
	body, _ := json.Marshal(readRequest{Account: c.Account, Generation: c.Generation, Conversations: []string{"200@s.whatsapp.net"}, RefreshNames: true, Limit: 1})
	req := httptest.NewRequest("POST", "/list_chats", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer synthetic")
	out := httptest.NewRecorder()
	api(j, "synthetic").ServeHTTP(out, req)
	if out.Code != 200 {
		t.Fatal(out.Code, out.Body.String())
	}
	var data map[string]any
	if err := json.Unmarshal(out.Body.Bytes(), &data); err != nil {
		t.Fatal(err)
	}
	if data["encoded_bytes"] != float64(out.Body.Len()) || data["rows_delivered"] != float64(1) || data["scope_kind"] != "selected" || data["name_refresh"].(map[string]any)["version"] != float64(1) || len(f.calls) != 1 || f.calls[0] != "200@s.whatsapp.net" {
		t.Fatal(data)
	}
	rows := data["conversations"].([]any)
	if rows[0].(map[string]any)["title"] != "Ana" {
		t.Fatal(rows)
	}
}

func TestMetadataRefreshAPIRefusesUnapprovedOrUnauthenticatedAndKeepsPageBudget(t *testing.T) {
	j := fixture(t)
	f := readyMetadata(t, j)
	j.observeTitle("200@s.whatsapp.net", "History", "history_conversation")
	// Existing API scope gate rejects selected-service account-wide expansion.
	c, _ := j.Config()
	if _, _, err := j.readScope(c, readRequest{AccountWide: true}, ""); err == nil {
		t.Fatal("scope widened")
	}
	j.mu.Lock()
	j.authenticated = false
	j.mu.Unlock()
	r, err := j.refreshNames(context.Background(), c, readRequest{Chat: "200@s.whatsapp.net", Limit: 1})
	if err != nil || r.Status != "not_authenticated" || len(f.calls) != 0 {
		t.Fatal(r, err)
	}
	page, _ := j.readPage(c, readRequest{Chat: "200@s.whatsapp.net", Limit: 1}, "list_chats")
	page["name_refresh"] = r
	b, err := marshalBytePage(page)
	if err != nil || len(b) > pageByteLimit {
		t.Fatal("page budget", err)
	}
}

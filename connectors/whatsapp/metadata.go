package main

import (
	"context"
	"encoding/json"
	"errors"
	"time"
	"unicode/utf8"

	"go.mau.fi/whatsmeow/types"
)

const nameRefreshRows = 32
const nameRefreshGroups = 3

type metadataReader interface {
	Check(context.Context, Config) error
	Name(context.Context, string) (string, string, error)
}
type sdkMetadata struct{ a *Adapter }

func (s *sdkMetadata) Check(ctx context.Context, c Config) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err := s.a.identity(); err != nil {
		return errors.New("metadata_identity_unproven")
	}
	current, err := s.a.journal.Config()
	if err != nil {
		return err
	}
	if current.Account != c.Account || current.Generation != c.Generation {
		return errors.New("account_generation_mismatch")
	}
	if !s.a.client.IsConnected() || !s.a.client.IsLoggedIn() {
		return errors.New("metadata_not_authenticated")
	}
	return nil
}
func contactLabel(c types.ContactInfo) (string, string) {
	if !c.Found {
		return "", ""
	}
	for _, v := range []struct{ text, source string }{{c.FullName, "sdk_contact_full_name"}, {c.FirstName, "sdk_contact_first_name"}, {c.BusinessName, "sdk_contact_business_name"}, {c.PushName, "sdk_contact_push_name"}} {
		if v.text != "" {
			return v.text, v.source
		}
	}
	return "", ""
}
func (s *sdkMetadata) Name(ctx context.Context, chat string) (string, string, error) {
	jid, err := types.ParseJID(chat)
	if err != nil {
		return "", "", errors.New("invalid_metadata_chat")
	}
	if jid.Server == types.GroupServer {
		// Only this observed, permitted group; never list all groups or fan out to members.
		bounded, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		info, err := s.a.client.GetGroupInfo(bounded, jid)
		if err != nil {
			return "", "", errors.New("group_metadata_unavailable")
		}
		if info == nil || info.JID.ToNonAD() != jid.ToNonAD() {
			return "", "", errors.New("group_metadata_scope_mismatch")
		}
		return info.Name, "sdk_group_query", nil
	}
	info, err := s.a.client.Store.Contacts.GetContact(ctx, jid)
	if err != nil {
		return "", "", errors.New("contact_cache_unavailable")
	}
	if title, source := contactLabel(info); title != "" {
		return title, source, nil
	}
	var alt, back types.JID
	if jid.Server == types.HiddenUserServer {
		alt, err = s.a.client.Store.LIDs.GetPNForLID(ctx, jid)
	} else {
		alt, err = s.a.client.Store.LIDs.GetLIDForPN(ctx, jid)
	}
	if err != nil {
		return "", "", errors.New("sdk_identity_map_unavailable")
	}
	if safeAlternate(jid, alt) == "" {
		return "", "", nil
	}
	if jid.Server == types.HiddenUserServer {
		back, err = s.a.client.Store.LIDs.GetLIDForPN(ctx, alt)
	} else {
		back, err = s.a.client.Store.LIDs.GetPNForLID(ctx, alt)
	}
	if err != nil {
		return "", "", errors.New("sdk_identity_map_unavailable")
	}
	if back.ToNonAD() != jid.ToNonAD() {
		return "", "", errors.New("sdk_identity_map_not_reciprocal")
	}
	info, err = s.a.client.Store.Contacts.GetContact(ctx, alt)
	if err != nil {
		return "", "", errors.New("mapped_contact_cache_unavailable")
	}
	title, source := contactLabel(info)
	if title != "" {
		source += "_via_sdk_lid_map"
	}
	return title, source, nil
}

type NameRefresh struct {
	Version        int    `json:"version"`
	Status         string `json:"status"`
	At             int64  `json:"at"`
	ScopeKind      string `json:"scope_kind"`
	Checked        int    `json:"checked"`
	Updated        int    `json:"updated"`
	Missing        int    `json:"missing"`
	Failed         int    `json:"failed"`
	Preserved      int    `json:"preserved_live_or_changed"`
	DeferredGroups int    `json:"deferred_groups"`
}

func (j *Journal) metadataGuard(c Config, r readRequest) error {
	now, err := j.scope(c.Account, c.Generation, "")
	if err != nil {
		return err
	}
	if _, _, err = j.readScope(now, r, ""); err != nil {
		return err
	}
	j.mu.Lock()
	ready := j.authenticated && j.verified && !j.pairingBlocked
	j.mu.Unlock()
	if !ready || now.PairingRequired {
		return errors.New("metadata_not_authenticated")
	}
	return nil
}
func validRefreshStatus(s string) bool {
	switch s {
	case "page_refreshed_partial_coverage", "not_authenticated", "busy", "unavailable", "authentication_changed", "scope_changed", "cache_write_failed", "cancelled", "deadline_exceeded", "partial_failures":
		return true
	}
	return false
}
func (j *Journal) refreshNames(ctx context.Context, c Config, r readRequest) (NameRefresh, error) {
	report := NameRefresh{Version: 1, Status: "page_refreshed_partial_coverage", At: time.Now().Unix(), ScopeKind: "selected"}
	if r.AccountWide {
		report.ScopeKind = "account"
	}
	if r.Query != "" || r.Limit < 1 || r.Limit > nameRefreshRows {
		return report, errors.New("refresh_requires_unfiltered_page_max32")
	}
	if !j.namesMu.TryLock() {
		report.Status = "busy"
		return report, nil
	}
	defer j.namesMu.Unlock()
	finish := func() (NameRefresh, error) {
		b, _ := json.Marshal(report)
		_, err := j.db.Exec("INSERT INTO name_refresh VALUES(?,?,?) ON CONFLICT(account,generation) DO UPDATE SET value=excluded.value", c.Account, c.Generation, string(b))
		return report, err
	}
	if j.metadata == nil {
		report.Status = "unavailable"
		return finish()
	}
	if checkErr := j.checkMetadata(ctx, c, r); checkErr != nil {
		report.Status = metadataFailure(checkErr)
		return finish()
	}
	where, args, err := j.readScope(c, r, "m.")
	if err != nil {
		return report, err
	}
	args = append(args, r.Before, r.Before, r.Limit)
	rows, err := j.db.Query("SELECT m.rowid,CASE WHEN typeof(m.chat)='text' AND length(CAST(m.chat AS BLOB))<=256 THEN m.chat ELSE '' END,"+versionExpr("chats", "m.rowid")+",m.title_source IN ('direct_sender_push_name','group_metadata') FROM chats m WHERE "+where+" AND (?=0 OR m.rowid<?) ORDER BY m.rowid DESC LIMIT ?", args...)
	if err != nil {
		return report, err
	}
	type candidate struct {
		row, version int64
		chat         string
		live         bool
	}
	page := []candidate{}
	for rows.Next() {
		var v candidate
		if err = rows.Scan(&v.row, &v.chat, &v.version, &v.live); err != nil {
			rows.Close()
			return report, err
		}
		page = append(page, v)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return report, err
	}
	// No network/cache query happens with a journal cursor, identity lock or DB transaction held.
	bounded, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	groups := 0
	for _, v := range page {
		if !validChat(v.chat) {
			report.Failed++
			report.Status = "partial_failures"
			continue
		}
		if bounded.Err() != nil {
			report.Status = "cancelled"
			if errors.Is(bounded.Err(), context.DeadlineExceeded) {
				report.Status = "deadline_exceeded"
			}
			break
		}
		if checkErr := j.checkMetadata(bounded, c, r); checkErr != nil {
			report.Status = metadataFailure(checkErr)
			break
		}
		jid, _ := types.ParseJID(v.chat)
		if jid.Server == types.GroupServer {
			if groups == nameRefreshGroups {
				report.DeferredGroups++
				continue
			}
			groups++
		}
		report.Checked++
		title, source, lookupErr := j.metadata.Name(bounded, v.chat)
		if bounded.Err() != nil {
			report.Status = "cancelled"
			if errors.Is(bounded.Err(), context.DeadlineExceeded) {
				report.Status = "deadline_exceeded"
			}
			break
		}
		if checkErr := j.checkMetadata(bounded, c, r); checkErr != nil {
			report.Status = metadataFailure(checkErr)
			break
		}
		if lookupErr != nil || !validMetadataTitleSource(source, title) || len(title) > 65536 || !utf8.ValidString(title) {
			report.Failed++
			report.Status = "partial_failures"
			continue
		}
		if title == "" {
			report.Missing++
			continue
		}
		j.identityMu.Lock()
		err = j.metadataGuard(c, r)
		if err == nil {
			result, e := j.db.Exec("UPDATE chats SET metadata_title=?,metadata_title_source=?,metadata_title_observed=?,title=CASE WHEN title_source IN ('direct_sender_push_name','group_metadata') THEN title ELSE ? END,title_source=CASE WHEN title_source IN ('direct_sender_push_name','group_metadata') THEN title_source ELSE ? END,title_observed=CASE WHEN title_source IN ('direct_sender_push_name','group_metadata') THEN title_observed ELSE ? END WHERE account=? AND generation=? AND rowid=? AND "+versionExpr("chats", "chats.rowid")+"=?", title, source, time.Now().Unix(), title, source, time.Now().Unix(), c.Account, c.Generation, v.row, v.version)
			err = e
			if e != nil {
				report.Failed++
				report.Status = "cache_write_failed"
			}
			if err == nil {
				n, _ := result.RowsAffected()
				if n == 1 {
					report.Updated++
					if v.live {
						report.Preserved++
					}
				} else {
					report.Preserved++
				}
			}
		}
		j.identityMu.Unlock()
		if err != nil {
			if report.Status != "cache_write_failed" {
				report.Status = metadataFailure(err)
			}
			break
		}
	}
	return finish()
}
func validMetadataTitleSource(source, title string) bool {
	if title == "" {
		return source == "" || source == "sdk_group_query"
	}
	switch source {
	case "sdk_group_query", "sdk_contact_full_name", "sdk_contact_first_name", "sdk_contact_business_name", "sdk_contact_push_name", "sdk_contact_full_name_via_sdk_lid_map", "sdk_contact_first_name_via_sdk_lid_map", "sdk_contact_business_name_via_sdk_lid_map", "sdk_contact_push_name_via_sdk_lid_map":
		return true
	}
	return false
}

func (j *Journal) checkMetadata(ctx context.Context, c Config, r readRequest) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := j.metadataGuard(c, r); err != nil {
		return err
	}
	return j.metadata.Check(ctx, c)
}
func metadataFailure(err error) string {
	if errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "deadline_exceeded"
	}
	switch err.Error() {
	case "metadata_not_authenticated", "metadata_identity_unproven":
		return "not_authenticated"
	case "account_generation_mismatch":
		return "authentication_changed"
	case "chat_not_authorized", "account_wide_not_approved", "explicit_read_scope_required":
		return "scope_changed"
	default:
		return "unavailable"
	}
}

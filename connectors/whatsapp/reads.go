package main

import (
	"encoding/json"
	"errors"
	"strings"
	"time"
)

type readRequest struct {
	Account       string   `json:"account"`
	Generation    int64    `json:"generation"`
	Chat          string   `json:"conversation_id"`
	Message       string   `json:"message_id"`
	Limit         int      `json:"limit"`
	Since         int64    `json:"since"`
	SentSince     int64    `json:"sent_since"`
	Before        int64    `json:"before"`
	Until         int64    `json:"until"`
	Query         string   `json:"query"`
	RefreshNames  bool     `json:"refresh_names"`
	Conversations []string `json:"conversations"`
	AccountWide   bool     `json:"account_wide"`
	Resource      string   `json:"resource"`
	Row           int64    `json:"row"`
	Field         string   `json:"field"`
	Offset        int64    `json:"offset"`
	Length        int      `json:"length"`
	Version       string   `json:"version"`
}

func (j *Journal) readScope(c Config, r readRequest, alias string) (string, []any, error) {
	args := []any{c.Account, c.Generation}
	where := alias + "account=? AND " + alias + "generation=?"
	if r.AccountWide {
		if !c.AllChats {
			return "", nil, errors.New("account_wide_not_approved")
		}
		if len(r.Conversations) > 0 || r.Chat != "" {
			return "", nil, errors.New("ambiguous_read_scope")
		}
		return where, args, nil
	}
	chats := r.Conversations
	if r.Chat != "" {
		if len(chats) > 0 {
			return "", nil, errors.New("ambiguous_read_scope")
		}
		chats = []string{r.Chat}
	}
	// Original selected-chat API compatibility; an account-wide service does NOT implicitly widen reads.
	if len(chats) == 0 {
		if c.AllChats {
			return "", nil, errors.New("explicit_read_scope_required")
		}
		chats = c.Chats
	}
	if len(chats) == 0 || len(chats) > 256 {
		return "", nil, errors.New("invalid_read_scope")
	}
	seen := map[string]bool{}
	slots := []string{}
	for _, chat := range chats {
		if !validChat(chat) || (!c.AllChats && !contains(c.Chats, chat)) {
			return "", nil, errors.New("chat_not_authorized")
		}
		if !seen[chat] {
			seen[chat] = true
			slots = append(slots, "?")
			args = append(args, chat)
		}
	}
	return where + " AND " + alias + "chat IN (" + strings.Join(slots, ",") + ")", args, nil
}
func (j *Journal) readPage(c Config, r readRequest, kind string) (map[string]any, error) {
	return j.readPageBudget(c, r, kind, pageByteLimit)
}
func (j *Journal) readPageBudget(c Config, r readRequest, kind string, budget int) (map[string]any, error) {
	limit := r.Limit
	if limit == 0 {
		limit = 2000
	}
	if limit < 1 || limit > 10000 || r.Since < 0 || r.Before < 0 || r.Until < 0 || r.SentSince < 0 || (r.Until > 0 && r.SentSince > r.Until) || len(r.Query) > 256 {
		return nil, errors.New("invalid_window")
	}
	if budget > pageByteLimit || budget <= pageEnvelopeReserve {
		return nil, errPageNoProgress
	}
	source, err := boundedSource(j, c)
	if err != nil {
		return nil, err
	}
	l, err := layout(kind)
	if err != nil {
		return nil, err
	}
	where, args, err := j.readScope(c, r, "m.")
	if err != nil {
		return nil, err
	}
	baseWhere, baseArgs := where, append([]any(nil), args...)
	if kind == "read_snapshot" {
		where += " AND m.observed>=?"
		args = append(args, r.Since)
		where += " AND (?=0 OR m.sent>=?) AND (?=0 OR m.sent<=?) AND (?='' OR instr(lower(m.body),lower(?))>0 OR instr(lower(COALESCE(a.transcript,'')),lower(?))>0)"
		args = append(args, r.SentSince, r.SentSince, r.Until, r.Until, r.Query, r.Query, r.Query)
	} else if kind == "list_chats" {
		where += " AND (?='' OR instr(lower(m.chat),lower(?))>0 OR instr(lower(m.title),lower(?))>0 OR instr(lower(m.metadata_title),lower(?))>0)"
		args = append(args, r.Query, r.Query, r.Query, r.Query)
	}
	where += " AND (?=0 OR m.rowid<?)"
	args = append(args, r.Before, r.Before, limit+1)
	rows, err := j.db.Query("SELECT "+projection(l)+" FROM "+l.table+" m"+l.join+" WHERE "+where+" ORDER BY m.rowid DESC LIMIT ?", args...)
	if err != nil {
		return nil, err
	}
	messages := []Message{}
	conversations := []map[string]any{}
	posts := []map[string]any{}
	oversized := []map[string]any{}
	order := []map[string]any{}
	seen := map[string]bool{}
	used, delivered := pageEnvelopeReserve, 0
	var lastDelivered int64
	more, byBytes, byRows := false, false, false
	for rows.Next() {
		if delivered == limit {
			more = true
			byRows = true
			break
		}
		row, e := scanCandidate(rows, l)
		if e != nil {
			rows.Close()
			return nil, e
		}
		value, inline := row.inline(l, kind)
		var encoded []byte
		if inline {
			encoded, e = json.Marshal(value)
			if e != nil {
				rows.Close()
				return nil, e
			}
			if len(encoded) > inlineRowBytes {
				inline = false
			}
		}
		outcomeKind, index := "inline", 0
		var descriptor map[string]any
		var chat map[string]any
		var chatBytes []byte
		if !inline {
			descriptor = row.descriptor(l, kind)
			encoded, e = json.Marshal(descriptor)
			outcomeKind = "oversized"
			index = len(oversized)
		} else if kind == "read_snapshot" {
			index = len(messages)
			m := value.(Message)
			if !seen[m.Chat] {
				chat = map[string]any{"id": m.Chat, "title": m.Chat, "archived": nil, "left": nil}
				chatBytes, e = json.Marshal(chat)
			}
		} else if kind == "list_chats" {
			index = len(conversations)
		} else {
			index = len(posts)
		}
		if e != nil {
			rows.Close()
			return nil, e
		}
		outcome := map[string]any{"cursor": row.row, "kind": outcomeKind, "index": index}
		outcomeBytes, e := json.Marshal(outcome)
		if e != nil {
			rows.Close()
			return nil, e
		}
		// Count exact row/summary/order JSON plus conservative array punctuation, BEFORE append.
		charge := len(encoded) + len(chatBytes) + len(outcomeBytes) + 16
		if used+charge > budget {
			more = true
			byBytes = true
			if delivered == 0 {
				rows.Close()
				return nil, errPageNoProgress
			}
			break
		}
		used += charge
		delivered++
		lastDelivered = row.row
		order = append(order, outcome)
		if !inline {
			oversized = append(oversized, descriptor)
		} else if kind == "read_snapshot" {
			m := value.(Message)
			messages = append(messages, m)
			if chat != nil {
				seen[m.Chat] = true
				conversations = append(conversations, chat)
			}
		} else if kind == "list_chats" {
			conversations = append(conversations, value.(map[string]any))
		} else {
			posts = append(posts, value.(map[string]any))
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	var lastObserved, invalidObserved int64
	if err = j.db.QueryRow("SELECT COALESCE(MAX(CASE WHEN typeof(m.observed)='integer' THEN m.observed ELSE NULL END),0),COALESCE(SUM(CASE WHEN typeof(m.observed)='integer' THEN 0 ELSE 1 END),0) FROM messages m WHERE "+baseWhere, baseArgs...).Scan(&lastObserved, &invalidObserved); err != nil {
		return nil, err
	}
	// Late metadata is fetched after closing the cursor, validated and included in the reserved envelope.
	source, err = boundedSource(j, c)
	if err != nil {
		return nil, err
	}
	source["last_journal_observed_at"] = lastObserved
	source["observation_metadata_valid"] = invalidObserved == 0
	source["invalid_observation_rows"] = invalidObserved
	next := int64(0)
	if more {
		next = lastDelivered
	}
	scopeKind := "selected"
	if r.AccountWide {
		scopeKind = "account"
	}
	data := map[string]any{"ok": true, "scope_kind": scopeKind, "account": c.Account, "generation": c.Generation, "messages": messages, "conversations": conversations, "posts": posts, "oversized_rows": oversized, "order": order, "rows_delivered": delivered, "inline_rows_delivered": delivered - len(oversized), "inline_complete": len(oversized) == 0, "truncated": more, "byte_truncated": byBytes, "row_truncated": byRows, "next_before": next, "cursor_version": 1, "page_version": 2, "cursor_semantics": "scoped live row-ID keyset window; not a pinned snapshot or cryptographic scope token", "limit_scope": "total", "byte_limit": pageByteLimit, "inline_field_byte_limit": inlineFieldBytes, "inline_row_byte_limit": inlineRowBytes, "coverage": "partial", "source_state": source, "snapshot_at": time.Now().Unix(), "draft_visibility": "unsupported"}
	if r.AccountWide {
		var excluded int
		if err = j.db.QueryRow("SELECT count(*) FROM excluded WHERE account=? AND generation=?", c.Account, c.Generation).Scan(&excluded); err != nil {
			return nil, err
		}
		data["excluded_scope_count"] = excluded
	}
	if kind == "list_chats" {
		data["names_version"] = 1
	}
	// Final HTTP encoding remains below the fixed budget, with no additional content fetch.
	return data, nil
}

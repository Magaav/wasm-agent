package main

import (
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
	Before        int64    `json:"before"`
	Conversations []string `json:"conversations"`
	AccountWide   bool     `json:"account_wide"`
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
	limit := r.Limit
	if limit == 0 {
		limit = 2000
	}
	if limit < 1 || limit > 10000 || r.Since < 0 || r.Before < 0 {
		return nil, errors.New("invalid_window")
	}
	where, args, err := j.readScope(c, r, "m.")
	if err != nil {
		return nil, err
	}
	baseWhere := where
	baseArgs := append([]any(nil), args...)
	table := "messages"
	cursor := "m.rowid"
	columns := `m.chat,m.id,m.sender,m.body,m.sent,m.own,m.history,m.audio,m.unsupported,COALESCE(a.transcript,''),COALESCE(a.state,''),COALESCE(a.reason,''),m.rowid,m.observed`
	join := ` LEFT JOIN audio a USING(account,generation,chat,id)`
	if kind == "list_chats" {
		table = "chats"
		columns = "m.chat,m.rowid,COALESCE(h.reason,'')"
		join = " LEFT JOIN chat_holds h USING(account,generation,chat)"
	} else if kind == "posting_status" {
		table = "outbox"
		columns = "m.chat,m.source,m.part,m.send_id,m.state,m.ack,COALESCE(r.reason,''),COALESCE(r.next_attempt,0),m.rowid"
		join = " LEFT JOIN post_retry r USING(account,generation,chat,source,part)"
	}
	if kind == "read_snapshot" {
		where += " AND m.observed>=?"
		args = append(args, r.Since)
	}
	where += " AND (?=0 OR " + cursor + "<?)"
	args = append(args, r.Before, r.Before, limit+1)
	rows, err := j.db.Query("SELECT "+columns+" FROM "+table+" m"+join+" WHERE "+where+" ORDER BY "+cursor+" DESC LIMIT ?", args...)
	if err != nil {
		return nil, err
	}
	messages := []Message{}
	conversations := []map[string]any{}
	posts := []map[string]any{}
	cursors := []int64{}
	seen := map[string]bool{}
	for rows.Next() {
		if kind == "read_snapshot" {
			var m Message
			err = rows.Scan(&m.Chat, &m.ID, &m.Sender, &m.Body, &m.Sent, &m.Own, &m.History, &m.Audio, &m.Unsupported, &m.Transcript, &m.AudioState, &m.AudioReason, &m.Cursor, &m.Observed)
			if err == nil {
				messages = append(messages, m)
				cursors = append(cursors, m.Cursor)
				if len(messages) <= limit && !seen[m.Chat] {
					seen[m.Chat] = true
					conversations = append(conversations, map[string]any{"id": m.Chat, "title": m.Chat, "archived": nil, "left": nil})
				}
			}
		} else if kind == "list_chats" {
			var chat, hold string
			var cursor int64
			err = rows.Scan(&chat, &cursor, &hold)
			if err == nil {
				conversations = append(conversations, map[string]any{"id": chat, "cursor": cursor, "posting_hold_reason": hold})
				cursors = append(cursors, cursor)
			}
		} else {
			var chat, source, id, state, ack, reason string
			var part int
			var next, cursor int64
			err = rows.Scan(&chat, &source, &part, &id, &state, &ack, &reason, &next, &cursor)
			if err == nil {
				posts = append(posts, map[string]any{"conversation_id": chat, "source_message_id": source, "part": part, "send_id": id, "state": state, "ack": ack, "reason": reason, "next_attempt": next, "cursor": cursor})
				cursors = append(cursors, cursor)
			}
		}
		if err != nil {
			rows.Close()
			return nil, err
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	more := len(cursors) > limit
	var next int64
	if more {
		next = cursors[limit-1]
		if len(messages) > limit {
			messages = messages[:limit]
		}
		if kind == "list_chats" {
			conversations = conversations[:limit]
		}
		if len(posts) > limit {
			posts = posts[:limit]
		}
	}
	var last int64
	if err = j.db.QueryRow("SELECT COALESCE(MAX(m.observed),0) FROM messages m WHERE "+baseWhere, baseArgs...).Scan(&last); err != nil {
		return nil, err
	}
	source := j.freshness()
	source["last_journal_observed_at"] = last
	scopeKind := "selected"
	if r.AccountWide {
		scopeKind = "account"
	}
	data := map[string]any{"ok": true, "scope_kind": scopeKind, "account": c.Account, "generation": c.Generation, "messages": messages, "conversations": conversations, "posts": posts, "truncated": more, "next_before": next, "cursor_version": 1, "limit_scope": "total", "coverage": "partial", "source_state": source, "snapshot_at": time.Now().Unix(), "draft_visibility": "unsupported"}
	if r.AccountWide {
		var excluded int
		if err = j.db.QueryRow("SELECT count(*) FROM excluded WHERE account=? AND generation=?", c.Account, c.Generation).Scan(&excluded); err != nil {
			return nil, err
		}
		data["excluded_scope_count"] = excluded
	}
	return data, nil
}

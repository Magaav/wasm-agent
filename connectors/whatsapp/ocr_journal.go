// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

const maxMediaBytes = 20 * 1024 * 1024

// OCR is a bounded local recognizer. It never receives protocol keys or URLs.
type OCR interface {
	Recognize(context.Context, string, string) (string, error)
}

func installMediaColumns(db *sql.DB) error {
	columns := []struct{ name, definition string }{
		{"media_kind", "TEXT NOT NULL DEFAULT ''"},
		{"media_state", "TEXT NOT NULL DEFAULT ''"},
		{"media_reason", "TEXT NOT NULL DEFAULT ''"},
		{"media_text", "TEXT NOT NULL DEFAULT ''"},
		{"media_attempts", "INTEGER NOT NULL DEFAULT 0"},
		{"media_next_attempt", "INTEGER NOT NULL DEFAULT 0"},
	}
	rows, err := db.Query("PRAGMA table_info(messages)")
	if err != nil {
		return err
	}
	present := map[string]bool{}
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull, primary int
		var def any
		if err = rows.Scan(&cid, &name, &typ, &notNull, &def, &primary); err != nil {
			rows.Close()
			return err
		}
		present[name] = true
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	for _, column := range columns {
		if present[column.name] {
			continue
		}
		if _, err = db.Exec("ALTER TABLE messages ADD COLUMN " + column.name + " " + column.definition); err != nil {
			return err
		}
	}
	return nil
}

func (j *Journal) processMedia(ctx context.Context, t Transport, r OCR) error {
	c, err := j.Config()
	if err != nil {
		return err
	}
	if !c.Requested || c.OCRDisabled {
		return nil
	}
	var m Message
	err = j.db.QueryRow(`SELECT chat,id,sent,own,media_kind,raw FROM messages WHERE account=? AND generation=? AND media_state='pending' AND media_next_attempt<=? ORDER BY media_attempts,observed LIMIT 1`, c.Account, c.Generation, time.Now().Unix()).Scan(&m.Chat, &m.ID, &m.Sent, &m.Own, &m.MediaKind, &m.Raw)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	b, err := t.Download(ctx, m)
	if err == nil && len(b) > maxMediaBytes {
		err = permanentError("image_too_large")
	}
	var text string
	path := filepath.Join(j.dir, "media-work")
	if err == nil {
		if err = os.WriteFile(path, b, 0600); err == nil {
			text, err = r.Recognize(ctx, path, c.Language)
		}
		os.Remove(path)
	}
	if err == nil && (!utf8.ValidString(text) || len([]rune(text)) > 12000) {
		err = permanentError("ocr_text_invalid_or_too_long")
	}
	if err == nil && strings.TrimSpace(text) == "" {
		err = permanentError("no_text_detected")
	}
	if err != nil {
		state := "pending"
		var p permanentError
		if errors.As(err, &p) {
			state = "unsupported"
		}
		_, e := j.db.Exec("UPDATE messages SET media_state=?,media_reason=?,media_attempts=media_attempts+1,media_next_attempt=? WHERE account=? AND generation=? AND chat=? AND id=?", state, safeReason(err), time.Now().Add(time.Minute).Unix(), c.Account, c.Generation, m.Chat, m.ID)
		return e
	}
	_, err = j.db.Exec("UPDATE messages SET media_state='ocr_done',media_reason='',media_text=? WHERE account=? AND generation=? AND chat=? AND id=?", text, c.Account, c.Generation, m.Chat, m.ID)
	return err
}

package main

import (
	"database/sql"
	"errors"
	"time"
	"unicode/utf8"
)

// Additive migration; old journals and evidence are retained. Titles are observed
// protocol labels, never identity/authentication proof or a name-to-JID merge.
func installDirectory(db *sql.DB) error {
	rows, err := db.Query("PRAGMA table_info(chats)")
	if err != nil {
		return err
	}
	columns := map[string]bool{}
	for rows.Next() {
		var cid, notnull, pk int
		var name, typ string
		var def any
		if err = rows.Scan(&cid, &name, &typ, &notnull, &def, &pk); err != nil {
			rows.Close()
			return err
		}
		columns[name] = true
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, col := range []struct{ name, decl string }{{"title", "TEXT NOT NULL DEFAULT ''"}, {"title_source", "TEXT NOT NULL DEFAULT ''"}, {"title_observed", "INTEGER NOT NULL DEFAULT 0"}, {"metadata_title", "TEXT NOT NULL DEFAULT ''"}, {"metadata_title_source", "TEXT NOT NULL DEFAULT ''"}, {"metadata_title_observed", "INTEGER NOT NULL DEFAULT 0"}} {
		if !columns[col.name] {
			if _, err = db.Exec("ALTER TABLE chats ADD COLUMN " + col.name + " " + col.decl); err != nil {
				return err
			}
		}
	}
	return nil
}
func (j *Journal) observeTitle(chat, title, source string) error {
	if title == "" {
		return nil
	}
	c, err := j.Config()
	if err != nil {
		return err
	}
	if !validChat(chat) || (!c.AllChats && !contains(c.Chats, chat)) {
		return nil
	}
	if len(title) > 65536 || !utf8.ValidString(title) {
		return errors.New("invalid_chat_title")
	}
	if source != "history_conversation" && source != "direct_sender_push_name" && source != "group_metadata" {
		return errors.New("invalid_title_source")
	}
	_, err = j.db.Exec("INSERT INTO chats(account,generation,chat,title,title_source,title_observed) VALUES(?,?,?,?,?,?) ON CONFLICT(account,generation,chat) DO UPDATE SET title=excluded.title,title_source=excluded.title_source,title_observed=excluded.title_observed WHERE excluded.title_source!='history_conversation' OR chats.title_source IN ('','history_conversation')", c.Account, c.Generation, chat, title, source, time.Now().Unix())
	return err
}

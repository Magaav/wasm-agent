package main

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode/utf8"
)

const pageByteLimit = 4 * 1024 * 1024
const pageEnvelopeReserve = 128 * 1024
const inlineFieldBytes = 64 * 1024
const inlineRowBytes = 512 * 1024
const fieldChunkBytes = 16 * 1024

var errPageNoProgress = errors.New("page_no_progress")

type pageField struct {
	name, expr, kind string
	owner            int
}
type pageLayout struct {
	table, join, secondary string
	fields                 []pageField
}

func layout(resource string) (pageLayout, error) {
	switch resource {
	case "read_snapshot":
		return pageLayout{"messages", " LEFT JOIN audio a USING(account,generation,chat,id)", "audio", []pageField{{"chat", "m.chat", "text", 0}, {"id", "m.id", "text", 0}, {"sender", "m.sender", "text", 0}, {"body", "m.body", "text", 0}, {"unsupported", "m.unsupported", "text", 0}, {"transcript", "COALESCE(a.transcript,'')", "text", 1}, {"audio_state", "COALESCE(a.state,'')", "text", 1}, {"audio_reason", "COALESCE(a.reason,'')", "text", 1}, {"sent_at", "m.sent", "integer", 0}, {"from_me", "m.own", "bool", 0}, {"history", "m.history", "bool", 0}, {"audio", "m.audio", "bool", 0}, {"media_kind", "m.media_kind", "text", 0}, {"media_state", "m.media_state", "text", 0}, {"media_text", "m.media_text", "text", 0}, {"media_reason", "m.media_reason", "text", 0}, {"observed_at", "m.observed", "integer", 0}}}, nil
	case "list_chats":
		return pageLayout{"chats", " LEFT JOIN chat_holds a USING(account,generation,chat)", "chat_holds", []pageField{{"chat", "m.chat", "text", 0}, {"posting_hold_reason", "COALESCE(a.reason,'')", "text", 1}, {"title", "m.title", "text", 0}, {"title_source", "m.title_source", "text", 0}, {"title_observed_at", "m.title_observed", "integer", 0}, {"metadata_title", "m.metadata_title", "text", 0}, {"metadata_title_source", "m.metadata_title_source", "text", 0}, {"metadata_title_observed_at", "m.metadata_title_observed", "integer", 0}}}, nil
	case "posting_status":
		return pageLayout{"outbox", " LEFT JOIN post_retry a USING(account,generation,chat,source,part)", "post_retry", []pageField{{"chat", "m.chat", "text", 0}, {"source_message_id", "m.source", "text", 0}, {"send_id", "m.send_id", "text", 0}, {"state", "m.state", "text", 0}, {"ack", "m.ack", "text", 0}, {"reason", "COALESCE(a.reason,'')", "text", 1}, {"part", "m.part", "integer", 0}, {"next_attempt", "COALESCE(a.next_attempt,0)", "integer", 1}}}, nil
	}
	return pageLayout{}, errors.New("invalid_read_resource")
}
func versionExpr(table, row string) string {
	return "COALESCE((SELECT CASE WHEN typeof(v.version)='integer' THEN v.version ELSE -1 END FROM read_versions v WHERE v.table_name='" + table + "' AND v.row_key=" + row + "),0)"
}
func installReadVersions(db *sql.DB) error {
	if _, err := db.Exec("CREATE TABLE IF NOT EXISTS read_versions(table_name TEXT NOT NULL,row_key INTEGER NOT NULL,version INTEGER NOT NULL,PRIMARY KEY(table_name,row_key))"); err != nil {
		return err
	}
	for _, table := range []string{"messages", "audio", "chats", "chat_holds", "outbox", "post_retry"} {
		for _, op := range []string{"INSERT", "UPDATE", "DELETE"} {
			row := "NEW.rowid"
			if op == "DELETE" {
				row = "OLD.rowid"
			}
			statement := "CREATE TRIGGER IF NOT EXISTS read_version_" + table + "_" + op + " AFTER " + op + " ON " + table + " BEGIN INSERT INTO read_versions VALUES('" + table + "'," + row + ",1) ON CONFLICT(table_name,row_key) DO UPDATE SET version=version+1; END"
			if _, err := db.Exec(statement); err != nil {
				return err
			}
		}
	}
	return nil
}

type candidate struct {
	row, version, other, otherVersion int64
	sizes                             []int64
	types                             []string
	values                            [][]byte
}

func projection(l pageLayout) string {
	cols := []string{"m.rowid", versionExpr(l.table, "m.rowid"), "COALESCE(a.rowid,0)", versionExpr(l.secondary, "a.rowid")}
	for _, f := range l.fields {
		blob := "CAST(" + f.expr + " AS BLOB)"
		cols = append(cols, "COALESCE(length("+blob+"),0)", "typeof("+f.expr+")", "CASE WHEN length("+blob+")<="+strconv.Itoa(inlineFieldBytes)+" THEN "+blob+" ELSE NULL END")
	}
	return strings.Join(cols, ",")
}
func scanCandidate(rows *sql.Rows, l pageLayout) (candidate, error) {
	r := candidate{sizes: make([]int64, len(l.fields)), types: make([]string, len(l.fields)), values: make([][]byte, len(l.fields))}
	args := []any{&r.row, &r.version, &r.other, &r.otherVersion}
	for i := range l.fields {
		args = append(args, &r.sizes[i], &r.types[i], &r.values[i])
	}
	err := rows.Scan(args...)
	if r.version < 0 || r.otherVersion < 0 {
		return r, errors.New("invalid_read_version")
	}
	return r, err
}
func (r candidate) fieldVersion(l pageLayout, f pageField) string {
	table, row, version := l.table, r.row, r.version
	if f.owner == 1 {
		table, row, version = l.secondary, r.other, r.otherVersion
	}
	return fmt.Sprintf("%s:%d:%d", table, row, version)
}
func (r candidate) descriptor(l pageLayout, resource string) map[string]any {
	fields := map[string]any{}
	for i, f := range l.fields {
		fields[f.name] = map[string]any{"byte_length": r.sizes[i], "sqlite_type": r.types[i], "field_version": r.fieldVersion(l, f)}
	}
	d := map[string]any{"resource": resource, "row": r.row, "cursor": r.row, "inline_complete": false, "reason": "oversized_or_non_inline_representation", "fields": fields, "retrieval": "read_field; base64 exact projected bytes"}
	if len(r.values) > 0 && r.sizes[0] <= 256 && utf8.Valid(r.values[0]) && validChat(string(r.values[0])) {
		d["conversation_id"] = string(r.values[0])
	}
	return d
}
func (r candidate) inline(l pageLayout, resource string) (any, bool) {
	text := map[string]string{}
	numbers := map[string]int64{}
	for i, f := range l.fields {
		if r.sizes[i] > inlineFieldBytes || int64(len(r.values[i])) != r.sizes[i] {
			return nil, false
		}
		if f.kind == "text" {
			if r.types[i] != "text" || !utf8.Valid(r.values[i]) {
				return nil, false
			}
			text[f.name] = string(r.values[i])
		} else {
			if r.types[i] != "integer" {
				return nil, false
			}
			v, err := strconv.ParseInt(string(r.values[i]), 10, 64)
			if err != nil || (f.kind == "bool" && v != 0 && v != 1) {
				return nil, false
			}
			numbers[f.name] = v
		}
	}
	if !validChat(text["chat"]) {
		return nil, false
	}
	switch resource {
	case "read_snapshot":
		return Message{Chat: text["chat"], ID: text["id"], Sender: text["sender"], Body: text["body"], Unsupported: text["unsupported"], Transcript: text["transcript"], AudioState: text["audio_state"], AudioReason: text["audio_reason"], MediaKind: text["media_kind"], MediaState: text["media_state"], MediaText: text["media_text"], MediaReason: text["media_reason"], Sent: numbers["sent_at"], Own: numbers["from_me"] == 1, History: numbers["history"] == 1, Audio: numbers["audio"] == 1, Observed: numbers["observed_at"], Cursor: r.row}, true
	case "list_chats":
		return map[string]any{"id": text["chat"], "title": text["title"], "title_source": text["title_source"], "title_observed_at": numbers["title_observed_at"], "metadata_title": text["metadata_title"], "metadata_title_source": text["metadata_title_source"], "metadata_title_observed_at": numbers["metadata_title_observed_at"], "posting_hold_reason": text["posting_hold_reason"], "cursor": r.row}, true
	default:
		return map[string]any{"conversation_id": text["chat"], "source_message_id": text["source_message_id"], "part": numbers["part"], "send_id": text["send_id"], "state": text["state"], "ack": text["ack"], "reason": text["reason"], "next_attempt": numbers["next_attempt"], "cursor": r.row}, true
	}
}
func boundedSource(j *Journal, c Config) (map[string]any, error) {
	if len(c.Account) > 256 {
		return nil, errPageNoProgress
	}
	s := j.freshness()
	if len(s) > 32 {
		return nil, errPageNoProgress
	}
	for _, v := range s {
		switch x := v.(type) {
		case string:
			if len(x) > 2048 {
				return nil, errPageNoProgress
			}
		case bool, int, int64:
		default:
			return nil, errPageNoProgress
		}
	}
	return s, nil
}

// Marshal only an incrementally bounded page, and include the final LF in encoded_bytes.
func marshalBytePage(data map[string]any) ([]byte, error) {
	data["encoded_bytes"] = 0
	for i := 0; i < 5; i++ {
		encoded, err := json.Marshal(data)
		if err != nil {
			return nil, err
		}
		n := len(encoded) + 1
		if n > pageByteLimit {
			return nil, errPageNoProgress
		}
		if data["encoded_bytes"] == n {
			return append(encoded, '\n'), nil
		}
		data["encoded_bytes"] = n
	}
	return nil, errPageNoProgress
}

type fieldReadError struct {
	status  int
	name    string
	version string
	size    int64
}

func (e *fieldReadError) Error() string { return e.name }
func (j *Journal) readField(c Config, r readRequest) (map[string]any, error) {
	l, err := layout(r.Resource)
	if err != nil {
		return nil, &fieldReadError{status: 400, name: "invalid_read_resource"}
	}
	if r.Row < 1 || r.Offset < 0 || r.Offset == math.MaxInt64 || r.Length < 0 || r.Length > fieldChunkBytes || len(r.Version) == 0 || len(r.Version) > 128 {
		return nil, &fieldReadError{status: 400, name: "invalid_field_window"}
	}
	length := r.Length
	if length == 0 {
		length = fieldChunkBytes
	}
	var field *pageField
	for i := range l.fields {
		if l.fields[i].name == r.Field {
			field = &l.fields[i]
			break
		}
	}
	if field == nil {
		return nil, &fieldReadError{status: 400, name: "field_not_readable"}
	}
	source, err := boundedSource(j, c)
	if err != nil {
		return nil, err
	}
	where, args, err := j.readScope(c, r, "m.")
	if err != nil {
		return nil, err
	}
	args = append([]any{r.Offset + 1, length}, args...)
	args = append(args, r.Row)
	blob := "CAST(" + field.expr + " AS BLOB)"
	ownerRow, table := "m.rowid", l.table
	if field.owner == 1 {
		ownerRow, table = "a.rowid", l.secondary
	}
	var owner, version, size int64
	var bytes []byte
	var sqliteType string
	var chat sql.NullString
	query := "SELECT COALESCE(" + ownerRow + ",0)," + versionExpr(table, ownerRow) + ",COALESCE(length(" + blob + "),0),typeof(" + field.expr + "),CASE WHEN length(CAST(m.chat AS BLOB))<=256 THEN m.chat ELSE NULL END,substr(" + blob + ",?,?) FROM " + l.table + " m" + l.join + " WHERE " + where + " AND m.rowid=?"
	err = j.db.QueryRow(query, args...).Scan(&owner, &version, &size, &sqliteType, &chat, &bytes)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, &fieldReadError{status: 404, name: "row_not_in_scope"}
	}
	if err != nil {
		return nil, err
	}
	if version < 0 {
		return nil, errors.New("invalid_read_version")
	}
	actual := fmt.Sprintf("%s:%d:%d", table, owner, version)
	if actual != r.Version {
		return nil, &fieldReadError{status: 409, name: "field_version_changed_restart", version: actual, size: size}
	}
	if r.Offset > size {
		return nil, &fieldReadError{status: 400, name: "offset_out_of_range", version: actual, size: size}
	}
	if len(bytes) > length || int64(len(bytes)) > size-r.Offset || (r.Offset < size && len(bytes) == 0) {
		return nil, errPageNoProgress
	}
	scopeKind := "selected"
	if r.AccountWide {
		scopeKind = "account"
	}
	data := map[string]any{"ok": true, "scope_kind": scopeKind, "account": c.Account, "generation": c.Generation, "resource": r.Resource, "row": r.Row, "field": r.Field, "field_version": actual, "byte_length": size, "offset": r.Offset, "next_offset": r.Offset + int64(len(bytes)), "chunk_bytes": len(bytes), "chunk_limit": fieldChunkBytes, "complete": r.Offset+int64(len(bytes)) == size, "sqlite_type": sqliteType, "content_encoding": "base64", "data_base64": base64.StdEncoding.EncodeToString(bytes), "source_state": source}
	if chat.Valid && validChat(chat.String) {
		data["conversation_id"] = chat.String
	}
	return data, nil
}

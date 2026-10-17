package main

import (
	"database/sql"
	"encoding/json"
	"errors"
)

// Aggregate-only owner status; never joins bodies, names, credentials or SDK nodes.
func (j *Journal) coverage(c Config) (map[string]any, error) {
	out := map[string]any{"version": 1, "scope": "current_generation_observed_journal_only", "history": "partial", "held_audio_policy": "preserved; no automatic reconciliation or replay"}
	var total, named, held, legacy int64
	err := j.db.QueryRow("SELECT count(*),COALESCE(sum(CASE WHEN title!='' OR metadata_title!='' THEN 1 ELSE 0 END),0) FROM chats WHERE account=? AND generation=?", c.Account, c.Generation).Scan(&total, &named)
	if err != nil {
		return nil, err
	}
	err = j.db.QueryRow("SELECT count(*),COALESCE(sum(CASE WHEN o.chat IS NULL THEN 1 ELSE 0 END),0) FROM chat_holds h LEFT JOIN hold_origins o USING(account,generation,chat) WHERE h.account=? AND h.generation=?", c.Account, c.Generation).Scan(&held, &legacy)
	if err != nil {
		return nil, err
	}
	out["observed_chats"] = total
	out["observed_titles"] = named
	out["unobserved_titles"] = total - named
	out["held_chats"] = held
	out["historical_reason_only_holds"] = legacy
	proof, err := j.mutationCoverage(c, "")
	if err != nil {
		return nil, err
	}
	out["mutation_diagnostics"] = proof
	var raw string
	err = j.db.QueryRow("SELECT value FROM name_refresh WHERE account=? AND generation=?", c.Account, c.Generation).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		out["last_name_refresh"] = nil
	} else if err != nil {
		return nil, err
	} else {
		var v NameRefresh
		if len(raw) > 2048 || json.Unmarshal([]byte(raw), &v) != nil || v.Version != 1 || !validRefreshStatus(v.Status) || (v.ScopeKind != "account" && v.ScopeKind != "selected") || v.At < 1 {
			return nil, errors.New("invalid_name_refresh_record")
		}
		for _, n := range []int{v.Checked, v.Updated, v.Missing, v.Failed, v.Preserved, v.DeferredGroups} {
			if n < 0 || n > nameRefreshRows {
				return nil, errors.New("invalid_name_refresh_record")
			}
		}
		out["last_name_refresh"] = v
	}
	return out, nil
}
func (j *Journal) mutationCoverage(c Config, chat string) (map[string]any, error) {
	var all, fenced, held, missing, ambiguous, mismatch, scope, invalid, owner, history int64
	err := j.db.QueryRow(`SELECT COALESCE(sum(n),0),COALESCE(sum(CASE WHEN decision='source_block' THEN n ELSE 0 END),0),COALESCE(sum(CASE WHEN decision='chat_hold' THEN n ELSE 0 END),0),COALESCE(sum(CASE WHEN author_proof='target_missing' THEN n ELSE 0 END),0),COALESCE(sum(CASE WHEN author_proof='ambiguous_author' THEN n ELSE 0 END),0),COALESCE(sum(CASE WHEN author_proof='author_mismatch' THEN n ELSE 0 END),0),COALESCE(sum(CASE WHEN scope_proof='remote_mismatch' THEN n ELSE 0 END),0),COALESCE(sum(CASE WHEN author_proof IN ('target_id_missing','target_id_invalid') THEN n ELSE 0 END),0),COALESCE(sum(CASE WHEN author_proof='owner_chat_operation' THEN n ELSE 0 END),0),COALESCE(sum(CASE WHEN stage='history' THEN n ELSE 0 END),0) FROM mutation_diagnostics WHERE account=? AND generation=? AND (?='' OR chat=?)`, c.Account, c.Generation, chat, chat).Scan(&all, &fenced, &held, &missing, &ambiguous, &mismatch, &scope, &invalid, &owner, &history)
	if err != nil {
		return nil, err
	}
	return map[string]any{"version": 1, "recorded_observations": all, "source_fence_decisions": fenced, "chat_hold_decisions": held, "source_not_available": missing, "ambiguous_author": ambiguous, "author_mismatch": mismatch, "scope_unproven": scope, "target_id_unproven": invalid, "owner_chat_hold_observations": owner, "history_observations": history, "semantics": "new processing observations, not unique messages or proof of historical hold origin"}, nil
}

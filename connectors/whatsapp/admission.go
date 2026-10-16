package main

import "errors"

// Only the owned adapter may return this BEFORE invoking the external SDK send.
// A generic SDK/transport error is never evidence of non-submission.
type notSubmittedError struct{ cause error }

func (e notSubmittedError) Error() string { return "definite_not_submitted" }
func (e notSubmittedError) Unwrap() error { return e.cause }
func noSubmission(reason string, permanent bool) error {
	if permanent {
		return notSubmittedError{cause: permanentError(reason)}
	}
	return notSubmittedError{cause: errors.New(reason)}
}
func (j *Journal) admitPost(c Config, m Message, part int) (bool, error) {
	j.effectMu.Lock()
	defer j.effectMu.Unlock()
	if j.hasGap() {
		return false, nil
	}
	current, err := j.scope(c.Account, c.Generation, m.Chat)
	if err != nil {
		return false, err
	}
	if !current.Requested {
		return false, nil
	}
	blocked, err := blockedSource(j.db, c, m.Chat, m.ID)
	if err != nil || blocked {
		return false, err
	}
	result, err := j.db.Exec("UPDATE outbox SET state='unknown',ack='dispatch intent; reconciliation required' WHERE account=? AND generation=? AND chat=? AND source=? AND part=? AND state='ready'", c.Account, c.Generation, m.Chat, m.ID, part)
	if err != nil {
		return false, err
	}
	n, err := result.RowsAffected()
	return n == 1, err
}

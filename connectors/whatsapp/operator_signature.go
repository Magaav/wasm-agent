// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

// The operator path signs every outbound message with a fixed template so the
// signature cannot be forgotten by whoever composes the text. This is a
// FORMATTING policy of the operator path only: it is not authentication of
// authorship and must never be presented as proof that a human wrote the
// message, nor used as identity evidence about the sender or the recipient.
//
// It is enforced where the body becomes exact - prepare - so that the text the
// approval binds IS the text that is sent. Nothing later injects a prefix: an
// invisible server-side addition would silently break the "approved text equals
// sent text" guarantee and the duplicate-intent hash.
import (
	"errors"
	"strings"
)

// operatorSignature is the one place the template is defined.
const operatorSignature = "🤖 _Copiloto_"

// operatorSignedBody returns body carrying the signature exactly once, on its
// own line.
//
// Strict rule: the body is already signed when it STARTS with the signature.
// In that case only a missing line break is repaired; the text is never
// duplicated. Any other body gets a signature line prepended.
func operatorSignedBody(body string) (string, error) {
	if body == "" {
		return "", errors.New("operator_text_invalid_or_too_large")
	}
	if !strings.HasPrefix(body, operatorSignature) {
		return operatorSignature + "\n" + body, nil
	}
	rest := body[len(operatorSignature):]
	if rest == "" || strings.HasPrefix(rest, "\n") {
		return body, nil
	}
	return operatorSignature + "\n" + rest, nil
}

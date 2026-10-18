// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// The template is composed where the body becomes exact, so these cases pin the
// rule rather than the rendering: exactly one signature line, no duplication,
// byte-exact UTF-8, and an explicit refusal instead of truncation.
func TestOperatorSignedBody(t *testing.T) {
	sig := "🤖 _Copiloto_"
	cases := []struct {
		name, in, want string
	}{
		{"unsigned text gains a signature line", "Bom dia, Laura", sig + "\nBom dia, Laura"},
		{"already signed is unchanged", sig + "\nBom dia", sig + "\nBom dia"},
		{"signature alone is unchanged", sig, sig},
		{"missing line break is repaired, not duplicated", sig + " Bom dia", sig + "\n Bom dia"},
		{"inline look-alike text is still signed once", "texto " + sig, sig + "\ntexto " + sig},
		{"multibyte body survives exactly", "ação 💛", sig + "\nação 💛"},
	}
	for _, c := range cases {
		got, err := operatorSignedBody(c.in)
		if err != nil {
			t.Fatalf("%s: unexpected error %v", c.name, err)
		}
		if got != c.want {
			t.Fatalf("%s: got %q want %q", c.name, got, c.want)
		}
		if !utf8.ValidString(got) {
			t.Fatalf("%s: result is not valid UTF-8", c.name)
		}
		if n := strings.Count(got, sig); n != 1 && !strings.Contains(c.name, "look-alike") {
			t.Fatalf("%s: signature appears %d times", c.name, n)
		}
	}
	if _, err := operatorSignedBody(""); err == nil {
		t.Fatal("empty body must refuse, not become a bare signature")
	}
}

// A signed body must not be re-signed by a second pass: the duplicate-intent
// path depends on the composed text being stable.
func TestOperatorSignedBodyIsStable(t *testing.T) {
	once, err := operatorSignedBody("mensagem")
	if err != nil {
		t.Fatal(err)
	}
	twice, err := operatorSignedBody(once)
	if err != nil {
		t.Fatal(err)
	}
	if once != twice {
		t.Fatalf("second pass changed the body: %q vs %q", once, twice)
	}
}

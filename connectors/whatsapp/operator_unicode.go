// Copyright 2026 wasm-agent contributors. SPDX-License-Identifier: MIT
package main

import (
	"encoding/json"
	"strconv"
	"unicode/utf8"
)

// encoding/json otherwise replaces invalid UTF-8 and unpaired surrogates. An
// approval boundary must reject those instead of silently changing exact text.
func exactOperatorJSON(b []byte) bool {
	if !utf8.Valid(b) || !json.Valid(b) {
		return false
	}
	inString := false
	for n := 0; n < len(b); n++ {
		if b[n] == '"' {
			inString = !inString
			continue
		}
		if !inString || b[n] != '\\' {
			continue
		}
		n++
		if n >= len(b) {
			return false
		}
		if b[n] != 'u' {
			continue
		}
		if n+4 >= len(b) {
			return false
		}
		v, err := strconv.ParseUint(string(b[n+1:n+5]), 16, 16)
		if err != nil {
			return false
		}
		n += 4
		if v >= 0xdc00 && v <= 0xdfff {
			return false
		}
		if v >= 0xd800 && v <= 0xdbff {
			if n+6 >= len(b) || b[n+1] != '\\' || b[n+2] != 'u' {
				return false
			}
			low, err := strconv.ParseUint(string(b[n+3:n+7]), 16, 16)
			if err != nil || low < 0xdc00 || low > 0xdfff {
				return false
			}
			n += 6
		}
	}
	return true
}

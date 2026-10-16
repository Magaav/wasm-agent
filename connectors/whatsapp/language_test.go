package main

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

type languageRecognizer struct{ languages []string }

func (r *languageRecognizer) Transcribe(_ context.Context, _ string, language string) (string, error) {
	r.languages = append(r.languages, language)
	return "áudio português original (" + language + ")", nil
}
func TestPersistedPortugueseTaskLanguageReachesRecognitionAndBothDirectionPosts(t *testing.T) {
	j := fixture(t)
	activate(t, j)
	c, err := j.Config()
	if err != nil {
		t.Fatal(err)
	}
	c.Language = "pt"
	if err = j.save(c); err != nil {
		t.Fatal(err)
	}
	for _, m := range []Message{audio("incoming-pt", false, 110), audio("phone-outgoing-pt", true, 120)} {
		if err = j.ingest(m); err != nil {
			t.Fatal(err)
		}
	}
	// Already queued work retains its persisted language, not a later process default.
	c.Language = "en"
	if err = j.save(c); err != nil {
		t.Fatal(err)
	}
	transport := &fakeTransport{}
	recognition := &languageRecognizer{}
	for i := 0; i < 2; i++ {
		if err = j.processAudio(context.Background(), transport, recognition); err != nil {
			t.Fatal(err)
		}
		if err = j.post(context.Background(), transport); err != nil {
			t.Fatal(err)
		}
	}
	if !reflect.DeepEqual(recognition.languages, []string{"pt", "pt"}) {
		t.Fatal("persisted PT did not reach recognizer", recognition.languages)
	}
	if transport.sent != 2 {
		t.Fatal("both directions not posted", transport.sent)
	}
	for _, body := range transport.bodies {
		if !strings.Contains(body, "áudio português original (pt)") || !strings.HasPrefix(body, "🎙️ _Automated transcript_") {
			t.Fatal("original-language text or marker changed", body)
		}
	}
}

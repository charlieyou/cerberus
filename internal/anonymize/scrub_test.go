package anonymize

import (
	"testing"
	"unicode/utf8"
)

func TestScrubFalsifiabilityCases(t *testing.T) {
	tests := []struct {
		name             string
		text             string
		peerID           string
		rosterModelNames []string
		want             string
	}{
		{
			name:   "cross reference",
			text:   "Claude said X",
			peerID: "peer_1",
			want:   "peer said X",
		},
		{
			name:   "self reference with commas",
			text:   "I, codex, recommend Y",
			peerID: "peer_2",
			want:   "I peer_2 recommend Y",
		},
		{
			name:   "self reference with article",
			text:   "as the gemini reviewer, I think Z",
			peerID: "peer_3",
			want:   "as the peer_3 reviewer, I think Z",
		},
		{
			name:   "self reference simple",
			text:   "As codex, my recommendation is Q",
			peerID: "peer_1",
			want:   "As peer_1, my recommendation is Q",
		},
		{
			name:   "doubled the edge case",
			text:   "as the the gemini reviewer",
			peerID: "peer_4",
			want:   "as the peer_4 reviewer",
		},
		{
			name:             "runtime roster model",
			text:             "Use Future.Model/7 and GPT-5.5",
			peerID:           "peer_1",
			rosterModelNames: []string{"future.model/7"},
			want:             "Use peer-model and peer-model",
		},
		{
			name:   "accepted false positive",
			text:   "claude_handler returned nil",
			peerID: "peer_1",
			want:   "peer_handler returned nil",
		},
		{
			name:             "self reference does not split model name",
			text:             "As claude-opus-4-7, I think Z",
			peerID:           "peer_1",
			rosterModelNames: []string{"claude-opus-4-7"},
			want:             "As peer-model, I think Z",
		},
		{
			name:   "provider before hyphen",
			text:   "codex-cli failed in internal/codex-client.go",
			peerID: "peer_1",
			want:   "peer-cli failed in internal/peer-client.go",
		},
		{
			name:             "overlapping roster models longest first",
			text:             "Use gpt-5.5-turbo, not gpt-5.5",
			peerID:           "peer_1",
			rosterModelNames: []string{"gpt-5.5", "gpt-5.5-turbo"},
			want:             "Use peer-model, not peer-model",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Scrub(tt.text, tt.peerID, tt.rosterModelNames); got != tt.want {
				t.Fatalf("Scrub() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestScrubRegexesArePrecompiled(t *testing.T) {
	if selfRefRe == nil || providerRe == nil || modelRe == nil {
		t.Fatal("scrub regexes must be precompiled")
	}
}

func TestScrubRosterModelReplacementPreservesUTF8BeforeMatch(t *testing.T) {
	got := Scrub("Use Kgpt-5.5 now", "peer_1", []string{"gpt-5.5"})
	if !utf8.ValidString(got) {
		t.Fatalf("Scrub() returned invalid UTF-8: %q", got)
	}
	if want := "Use Kpeer-model now"; got != want {
		t.Fatalf("Scrub() = %q, want %q", got, want)
	}
}

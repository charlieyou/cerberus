package anonymize

import "testing"

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

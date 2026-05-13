package anonymize

import (
	"reflect"
	"testing"

	"github.com/charlieyou/cerberus/internal/reviewer"
)

func TestAnonymizePeerBroadcastAssignsPeerIDsLexicographicallyAndScrubsText(t *testing.T) {
	confidence := 0.81
	severity := "high"
	priority := 1
	lineStart := 12
	lineEnd := 13
	strategy := "codex-falsification"
	modelStrategy := "claude-opus-4-7"
	round := 1
	outputs := []reviewer.RawReviewerOutput{
		rawOutput("codex#2", "NEEDS_WORK", "codex on gpt-5.5 found Y", confidence, strategy, round, severity, priority, lineStart, lineEnd),
		rawOutput("gemini#1", "NEEDS_WORK", "gemini on gemini-3.1-pro found Z", confidence, strategy, round, severity, priority, lineStart, lineEnd),
		rawOutput("claude#1", "NEEDS_WORK", "claude on claude-opus-4-7 found X", confidence, strategy, round, severity, priority, lineStart, lineEnd),
		rawOutput("codex#1", "PASS", "As codex, I agree", confidence, strategy, round, severity, priority, lineStart, lineEnd),
	}
	outputs[2].Strategy = &modelStrategy
	models := []string{"claude-opus-4-7", "gpt-5.5", "gemini-3.1-pro"}

	got, err := AnonymizePeerBroadcast(outputs, models, 1)
	if err != nil {
		t.Fatalf("AnonymizePeerBroadcast() error = %v", err)
	}
	wantIDs := []string{"peer_1", "peer_2", "peer_3", "peer_4"}
	if gotIDs := peerIDs(got); !reflect.DeepEqual(gotIDs, wantIDs) {
		t.Fatalf("peer IDs = %v, want %v", gotIDs, wantIDs)
	}
	if got[0].Summary != "peer on peer-model found X" {
		t.Fatalf("claude summary = %q, want scrubbed provider/model", got[0].Summary)
	}
	if got[1].Summary != "As peer_2, I agree" {
		t.Fatalf("codex self-reference summary = %q, want peer_2 attribution", got[1].Summary)
	}
	if got[0].Verdict != "pass" || got[1].Verdict != "pass" {
		t.Fatalf("verdicts not derived from findings: %#v", got)
	}
	if got[0].OverallConfidence == nil || *got[0].OverallConfidence != confidence {
		t.Fatalf("overall confidence = %v, want %v", got[0].OverallConfidence, confidence)
	}
	if got[0].Strategy == nil || *got[0].Strategy != "peer-model" {
		t.Fatalf("model strategy = %v, want scrubbed peer-model", got[0].Strategy)
	}
	if got[1].Strategy == nil || *got[1].Strategy != "peer-falsification" {
		t.Fatalf("provider strategy = %v, want scrubbed peer-falsification", got[1].Strategy)
	}
	if got[0].Round == nil || *got[0].Round != round {
		t.Fatalf("round = %v, want %d", got[0].Round, round)
	}
	if got[0].Findings[0].Severity == nil || *got[0].Findings[0].Severity != severity {
		t.Fatalf("severity = %v, want %q", got[0].Findings[0].Severity, severity)
	}
	if got[0].Findings[0].Confidence == nil || *got[0].Findings[0].Confidence != confidence {
		t.Fatalf("finding confidence = %v, want %v", got[0].Findings[0].Confidence, confidence)
	}
	if got[0].Findings[0].Evidence != "peer evidence uses peer-model" || got[0].Findings[0].Recommendation != "ask peer to fix" {
		t.Fatalf("finding free text not scrubbed: %#v", got[0].Findings[0])
	}
	if got[0].Findings[0].FilePath == nil || *got[0].Findings[0].FilePath != "internal/peer/client.go" {
		t.Fatalf("finding file path = %v, want scrubbed provider path", got[0].Findings[0].FilePath)
	}

	shuffled := []reviewer.RawReviewerOutput{outputs[3], outputs[0], outputs[2], outputs[1]}
	again, err := AnonymizePeerBroadcast(shuffled, models, 1)
	if err != nil {
		t.Fatalf("AnonymizePeerBroadcast(shuffled) error = %v", err)
	}
	if !reflect.DeepEqual(got, again) {
		t.Fatalf("shuffled output changed:\n got: %#v\nwant: %#v", again, got)
	}
}

func TestAnonymizePeerBroadcastKeepsPeerIDsStableForAccumulatedRounds(t *testing.T) {
	confidence := 0.81
	severity := "high"
	priority := 1
	lineStart := 12
	lineEnd := 13
	strategy := "verification-first"
	roundOne := 1
	roundTwo := 2
	outputs := []reviewer.RawReviewerOutput{
		rawOutput("claude#1", "NEEDS_WORK", "as claude, round one", confidence, strategy, roundOne, severity, priority, lineStart, lineEnd),
		rawOutput("codex#1", "NEEDS_WORK", "as codex, round one", confidence, strategy, roundOne, severity, priority, lineStart, lineEnd),
		rawOutput("claude#1", "PASS", "as claude, round two", confidence, strategy, roundTwo, severity, priority, lineStart, lineEnd),
		rawOutput("codex#1", "PASS", "as codex, round two", confidence, strategy, roundTwo, severity, priority, lineStart, lineEnd),
	}

	got, err := AnonymizePeerBroadcast(outputs, nil, 1)
	if err != nil {
		t.Fatalf("AnonymizePeerBroadcast() error = %v", err)
	}
	if gotIDs := peerIDs(got); !reflect.DeepEqual(gotIDs, []string{"peer_1", "peer_2"}) {
		t.Fatalf("peer IDs = %v, want stable unique IDs", gotIDs)
	}
	if got[0].Summary != "as peer_1, round two" || got[1].Summary != "as peer_2, round two" {
		t.Fatalf("summaries = %q, %q; want latest round with stable peer IDs", got[0].Summary, got[1].Summary)
	}
	if got[0].Round == nil || *got[0].Round != roundTwo || got[1].Round == nil || *got[1].Round != roundTwo {
		t.Fatalf("rounds = %v, %v; want latest round", got[0].Round, got[1].Round)
	}
}

func TestAnonymizePeerBroadcastUsesFailurePriority(t *testing.T) {
	confidence := 0.81
	severity := "medium"
	priority := 2
	lineStart := 12
	lineEnd := 13
	strategy := "verification-first"
	round := 1
	outputs := []reviewer.RawReviewerOutput{
		rawOutput("codex#1", "NEEDS_WORK", "p2 finding", confidence, strategy, round, severity, priority, lineStart, lineEnd),
	}

	defaultThreshold, err := AnonymizePeerBroadcast(outputs, nil, 1)
	if err != nil {
		t.Fatalf("AnonymizePeerBroadcast(default threshold) error = %v", err)
	}
	if defaultThreshold[0].Verdict != "pass" {
		t.Fatalf("default-threshold verdict = %q, want pass", defaultThreshold[0].Verdict)
	}

	p2Threshold, err := AnonymizePeerBroadcast(outputs, nil, 2)
	if err != nil {
		t.Fatalf("AnonymizePeerBroadcast(p2 threshold) error = %v", err)
	}
	if p2Threshold[0].Verdict != "fail" {
		t.Fatalf("p2-threshold verdict = %q, want fail", p2Threshold[0].Verdict)
	}
}

func TestAnonymizePeerBroadcastEmptyInput(t *testing.T) {
	got, err := AnonymizePeerBroadcast(nil, nil, 1)
	if err != nil {
		t.Fatalf("AnonymizePeerBroadcast(nil) error = %v", err)
	}
	if got == nil || len(got) != 0 {
		t.Fatalf("AnonymizePeerBroadcast(nil) = %#v, want empty non-nil slice", got)
	}
}

func TestAnonymizePeerBroadcastRejectsMissingInstanceID(t *testing.T) {
	_, err := AnonymizePeerBroadcast([]reviewer.RawReviewerOutput{{Findings: []reviewer.RawFinding{}, Verdict: "PASS"}}, nil, 1)
	if err == nil {
		t.Fatal("AnonymizePeerBroadcast() error = nil, want missing instance ID error")
	}
}

func rawOutput(instanceID, verdict, summary string, confidence float64, strategy string, round int, severity string, priority int, lineStart int, lineEnd int) reviewer.RawReviewerOutput {
	filePath := "internal/claude/client.go"
	findings := []reviewer.RawFinding{}
	if verdict != "PASS" {
		if priority <= 1 {
			priority = 2
		}
		findings = []reviewer.RawFinding{
			{
				Title:          "Claude title",
				Body:           "Gemini body",
				Severity:       &severity,
				Priority:       &priority,
				FilePath:       &filePath,
				LineStart:      &lineStart,
				LineEnd:        &lineEnd,
				Confidence:     &confidence,
				Evidence:       "Claude evidence uses claude-opus-4-7",
				Recommendation: "ask claude to fix",
			},
		}
	}
	return reviewer.RawReviewerOutput{
		InstanceID:        instanceID,
		Summary:           summary,
		OverallConfidence: &confidence,
		Strategy:          &strategy,
		Round:             &round,
		PeerResponsesSeen: []string{},
		Findings:          findings,
	}
}

func peerIDs(records []PeerRecord) []string {
	ids := make([]string, len(records))
	for i, record := range records {
		ids[i] = record.PeerID
	}
	return ids
}

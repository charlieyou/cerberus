package aggregate

import (
	"strings"
	"testing"

	"github.com/charlieyou/cerberus/internal/reviewer"
)

func TestComputeMajority(t *testing.T) {
	for _, tc := range []struct {
		name    string
		outputs []reviewer.RawReviewerOutput
		want    string
	}{
		{
			name: "pass strict majority",
			outputs: []reviewer.RawReviewerOutput{
				output("PASS", 0.1),
				output("PASS", 0.1),
				output("FAIL", 1),
			},
			want: VerdictPass,
		},
		{
			name: "fail strict majority",
			outputs: []reviewer.RawReviewerOutput{
				output("PASS", 1),
				output("FAIL", 0.1),
				output("FAIL", 0.1),
			},
			want: VerdictFail,
		},
		{
			name: "pass fail tie fails",
			outputs: []reviewer.RawReviewerOutput{
				output("PASS", 1),
				output("FAIL", 1),
			},
			want: VerdictFail,
		},
		{
			name: "non-failing findings count as pass votes",
			outputs: []reviewer.RawReviewerOutput{
				output("PASS", 1),
				output("FAIL", 1),
				output("NEEDS_WORK", 1),
			},
			want: VerdictPass,
		},
		{
			name: "non-failing findings strict majority passes",
			outputs: []reviewer.RawReviewerOutput{
				output("PASS", 1),
				output("NEEDS_WORK", 1),
				output("NEEDS_WORK", 1),
			},
			want: VerdictPass,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Compute(tc.outputs, ModeMajority, DefaultFailurePriority)
			if err != nil {
				t.Fatalf("Compute() error = %v", err)
			}
			if got.Verdict != tc.want {
				t.Fatalf("Verdict = %q, want %q", got.Verdict, tc.want)
			}
		})
	}
}

func TestComputeMajorityHandlesNullConfidenceByReviewerCount(t *testing.T) {
	got, err := Compute([]reviewer.RawReviewerOutput{
		outputWithoutConfidence("PASS"),
		outputWithoutConfidence("PASS"),
		output("FAIL", 1),
	}, ModeMajority, DefaultFailurePriority)
	if err != nil {
		t.Fatalf("Compute() error = %v", err)
	}
	if got.Verdict != VerdictPass {
		t.Fatalf("Verdict = %q, want %q", got.Verdict, VerdictPass)
	}
}

func TestComputeAll(t *testing.T) {
	got, err := Compute([]reviewer.RawReviewerOutput{
		output("PASS", 1),
		output("NEEDS_WORK", 1),
	}, ModeAll, DefaultFailurePriority)
	if err != nil {
		t.Fatalf("Compute() error = %v", err)
	}
	if got.Verdict != VerdictPass {
		t.Fatalf("Verdict = %q, want %q", got.Verdict, VerdictPass)
	}
}

func TestComputeUsesFailurePriorityThreshold(t *testing.T) {
	got, err := Compute([]reviewer.RawReviewerOutput{
		output("NEEDS_WORK", 1),
	}, ModeAll, 2)
	if err != nil {
		t.Fatalf("Compute() error = %v", err)
	}
	if got.Verdict != VerdictFail {
		t.Fatalf("Verdict = %q, want %q", got.Verdict, VerdictFail)
	}
}

func TestComputeAny(t *testing.T) {
	got, err := Compute([]reviewer.RawReviewerOutput{
		output("FAIL", 1),
		output("PASS", 1),
	}, ModeAny, DefaultFailurePriority)
	if err != nil {
		t.Fatalf("Compute() error = %v", err)
	}
	if got.Verdict != VerdictPass {
		t.Fatalf("Verdict = %q, want %q", got.Verdict, VerdictPass)
	}
}

func TestBlockingFindingPreventsPassAcrossModes(t *testing.T) {
	for _, mode := range []Mode{ModeMajority, ModeAll, ModeAny} {
		t.Run(string(mode), func(t *testing.T) {
			got, err := Compute([]reviewer.RawReviewerOutput{
				output("PASS", 1, blockingFinding()),
			}, mode, DefaultFailurePriority)
			if err != nil {
				t.Fatalf("Compute() error = %v", err)
			}
			if got.Verdict == VerdictPass {
				t.Fatalf("Verdict = %q, want non-pass", got.Verdict)
			}
			if len(got.Blockers) != 1 || got.Blockers[0].Title != "blocks release" {
				t.Fatalf("Blockers = %#v, want blocking finding", got.Blockers)
			}
		})
	}
}

func TestNormalizeVerdict(t *testing.T) {
	for raw, want := range map[string]string{
		"PASS":              VerdictPass,
		"pass":              VerdictPass,
		"FAIL":              VerdictFail,
		"fail":              VerdictFail,
		"NEEDS_WORK":        VerdictNeedsWork,
		"NEEDS WORK":        VerdictNeedsWork,
		"needs_work":        VerdictNeedsWork,
		"REQUIRES_DECISION": VerdictRequiresDecision,
		"requires_decision": VerdictRequiresDecision,
	} {
		t.Run(raw, func(t *testing.T) {
			got, err := NormalizeVerdict(raw)
			if err != nil {
				t.Fatalf("NormalizeVerdict() error = %v", err)
			}
			if got != want {
				t.Fatalf("NormalizeVerdict() = %q, want %q", got, want)
			}
		})
	}
}

func TestNormalizeVerdictUnknownReturnsError(t *testing.T) {
	_, err := NormalizeVerdict("MAYBE")
	if err == nil {
		t.Fatal("NormalizeVerdict() error = nil, want unknown verdict error")
	}
	if !strings.Contains(err.Error(), "unknown reviewer verdict") {
		t.Fatalf("NormalizeVerdict() error = %q, want unknown verdict message", err)
	}
}

func output(verdict string, confidence float64, findings ...reviewer.RawFinding) reviewer.RawReviewerOutput {
	if len(findings) == 0 {
		findings = findingsForVerdict(verdict)
	}
	return reviewer.RawReviewerOutput{
		OverallConfidence: &confidence,
		Findings:          findings,
	}
}

func outputWithoutConfidence(verdict string, findings ...reviewer.RawFinding) reviewer.RawReviewerOutput {
	if len(findings) == 0 {
		findings = findingsForVerdict(verdict)
	}
	return reviewer.RawReviewerOutput{
		Findings: findings,
	}
}

func findingsForVerdict(verdict string) []reviewer.RawFinding {
	switch verdict {
	case "FAIL", "fail":
		priority := 1
		return []reviewer.RawFinding{{Title: "fail", Body: "fail", Priority: &priority}}
	case "NEEDS_WORK", "NEEDS WORK", "needs_work":
		priority := 2
		return []reviewer.RawFinding{{Title: "needs work", Body: "needs work", Priority: &priority}}
	default:
		return []reviewer.RawFinding{}
	}
}

func blockingFinding() reviewer.RawFinding {
	severity := "blocking"
	return reviewer.RawFinding{
		Title:    "blocks release",
		Severity: &severity,
	}
}

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
			name: "tie requires decision",
			outputs: []reviewer.RawReviewerOutput{
				output("PASS", 1),
				output("FAIL", 1),
			},
			want: VerdictRequiresDecision,
		},
		{
			name: "split with needs work requires decision",
			outputs: []reviewer.RawReviewerOutput{
				output("PASS", 1),
				output("FAIL", 1),
				output("NEEDS_WORK", 1),
			},
			want: VerdictRequiresDecision,
		},
		{
			name: "needs work strict majority",
			outputs: []reviewer.RawReviewerOutput{
				output("PASS", 1),
				output("NEEDS_WORK", 1),
				output("NEEDS_WORK", 1),
			},
			want: VerdictNeedsWork,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Compute(tc.outputs, ModeMajority)
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
	}, ModeMajority)
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
	}, ModeAll)
	if err != nil {
		t.Fatalf("Compute() error = %v", err)
	}
	if got.Verdict != VerdictNeedsWork {
		t.Fatalf("Verdict = %q, want %q", got.Verdict, VerdictNeedsWork)
	}
}

func TestComputeAllPreservesRequiresDecision(t *testing.T) {
	got, err := Compute([]reviewer.RawReviewerOutput{
		output("PASS", 1),
		output("requires_decision", 1),
	}, ModeAll)
	if err != nil {
		t.Fatalf("Compute() error = %v", err)
	}
	if got.Verdict != VerdictRequiresDecision {
		t.Fatalf("Verdict = %q, want %q", got.Verdict, VerdictRequiresDecision)
	}
}

func TestComputeAny(t *testing.T) {
	got, err := Compute([]reviewer.RawReviewerOutput{
		output("FAIL", 1),
		output("PASS", 1),
	}, ModeAny)
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
			}, mode)
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
	return reviewer.RawReviewerOutput{
		Verdict:           verdict,
		OverallConfidence: &confidence,
		Findings:          findings,
	}
}

func outputWithoutConfidence(verdict string, findings ...reviewer.RawFinding) reviewer.RawReviewerOutput {
	return reviewer.RawReviewerOutput{
		Verdict:  verdict,
		Findings: findings,
	}
}

func blockingFinding() reviewer.RawFinding {
	severity := "blocking"
	return reviewer.RawFinding{
		Title:    "blocks release",
		Severity: &severity,
	}
}

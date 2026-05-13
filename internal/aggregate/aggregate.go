package aggregate

import (
	"fmt"
	"strings"

	"github.com/charlieyou/cerberus/internal/reviewer"
)

type Mode string

const (
	ModeMajority Mode = "majority"
	ModeAll      Mode = "all"
	ModeAny      Mode = "any"
)

type Result struct {
	Verdict  string
	Blockers []FindingRef
}

const DefaultFailurePriority = 1

type FindingRef struct {
	ReviewerIndex int
	Title         string
	FilePath      string
	LineStart     int
	LineEnd       int
}

func Compute(outputs []reviewer.RawReviewerOutput, mode Mode, failurePriority int) (Result, error) {
	if len(outputs) == 0 {
		return Result{}, fmt.Errorf("aggregate reviewer outputs: none provided")
	}

	mode = normalizeMode(mode)
	failurePriority = normalizeFailurePriority(failurePriority)
	counts := map[string]int{
		VerdictPass:             0,
		VerdictFail:             0,
		VerdictNeedsWork:        0,
		VerdictRequiresDecision: 0,
	}
	var blockers []FindingRef
	allPass := true
	anyPass := false
	anyNeedsWork := false
	anyRequiresDecision := false

	for index, output := range outputs {
		verdict := VerdictForFindings(output.Findings, failurePriority)
		allPass = allPass && verdict == VerdictPass
		anyPass = anyPass || verdict == VerdictPass
		anyNeedsWork = anyNeedsWork || verdict == VerdictNeedsWork
		anyRequiresDecision = anyRequiresDecision || verdict == VerdictRequiresDecision
		counts[verdict]++
		blockers = append(blockers, blockingFindings(index, output.Findings)...)
	}

	if len(blockers) > 0 {
		return Result{Verdict: VerdictFail, Blockers: blockers}, nil
	}

	return Result{Verdict: computeVerdict(counts, len(outputs), mode, allPass, anyPass, anyNeedsWork, anyRequiresDecision)}, nil
}

// VerdictForFindings derives the per-reviewer verdict from findings emitted by
// a CLI reviewer. Reviewers no longer vote directly.
func VerdictForFindings(findings []reviewer.RawFinding, failurePriority int) string {
	if len(findings) == 0 {
		return VerdictPass
	}
	failurePriority = normalizeFailurePriority(failurePriority)
	for _, finding := range findings {
		if finding.Severity != nil && strings.ToLower(*finding.Severity) == "blocking" {
			return VerdictFail
		}
		if finding.Priority != nil && *finding.Priority <= failurePriority {
			return VerdictFail
		}
	}
	return VerdictPass
}

func normalizeFailurePriority(priority int) int {
	if priority < 0 || priority > 3 {
		return DefaultFailurePriority
	}
	return priority
}

func normalizeMode(mode Mode) Mode {
	switch mode {
	case "", ModeMajority:
		return ModeMajority
	case ModeAll, ModeAny:
		return mode
	default:
		return ModeMajority
	}
}

func computeVerdict(counts map[string]int, count int, mode Mode, allPass bool, anyPass bool, anyNeedsWork bool, anyRequiresDecision bool) string {
	switch mode {
	case ModeAll:
		if allPass {
			return VerdictPass
		}
		if anyRequiresDecision {
			return VerdictRequiresDecision
		}
		if counts[VerdictFail] == 0 && anyNeedsWork {
			return VerdictNeedsWork
		}
		return VerdictFail
	case ModeAny:
		if anyPass {
			return VerdictPass
		}
		if anyNeedsWork {
			return VerdictNeedsWork
		}
		if anyRequiresDecision {
			return VerdictRequiresDecision
		}
		return VerdictFail
	default:
		if counts[VerdictPass] > count/2 {
			return VerdictPass
		}
		if counts[VerdictFail] > count/2 {
			return VerdictFail
		}
		if counts[VerdictNeedsWork] > count/2 {
			return VerdictNeedsWork
		}
		return VerdictRequiresDecision
	}
}

func blockingFindings(reviewerIndex int, findings []reviewer.RawFinding) []FindingRef {
	var blockers []FindingRef
	for _, finding := range findings {
		if finding.Severity == nil || strings.ToLower(*finding.Severity) != "blocking" {
			continue
		}
		ref := FindingRef{
			ReviewerIndex: reviewerIndex,
			Title:         finding.Title,
		}
		if finding.FilePath != nil {
			ref.FilePath = *finding.FilePath
		}
		if finding.LineStart != nil {
			ref.LineStart = *finding.LineStart
		}
		if finding.LineEnd != nil {
			ref.LineEnd = *finding.LineEnd
		}
		blockers = append(blockers, ref)
	}
	return blockers
}

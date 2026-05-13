package aggregate

import "fmt"

const (
	VerdictPass             = "pass"
	VerdictFail             = "fail"
	VerdictNeedsWork        = "needs_work"
	VerdictRequiresDecision = "requires_decision"
)

// NormalizeVerdict maps the raw reviewer JSON verdict into the gate verdict.
func NormalizeVerdict(raw string) (string, error) {
	switch raw {
	case "PASS", "pass":
		return VerdictPass, nil
	case "FAIL", "fail":
		return VerdictFail, nil
	case "NEEDS_WORK", "NEEDS WORK", "needs_work":
		return VerdictNeedsWork, nil
	case "REQUIRES_DECISION", "requires_decision":
		return VerdictRequiresDecision, nil
	default:
		return "", fmt.Errorf("unknown reviewer verdict %q", raw)
	}
}

package aggregate

import "fmt"

const (
	VerdictPass             = "pass"
	VerdictFail             = "fail"
	VerdictRequiresDecision = "requires_decision"
)

// NormalizeVerdict maps the raw reviewer JSON verdict into the gate verdict.
func NormalizeVerdict(raw string) (string, error) {
	switch raw {
	case "PASS":
		return VerdictPass, nil
	case "FAIL":
		return VerdictFail, nil
	case "NEEDS_WORK", "NEEDS WORK", "REQUIRES_DECISION", "requires_decision":
		return VerdictRequiresDecision, nil
	default:
		return "", fmt.Errorf("unknown reviewer verdict %q", raw)
	}
}

package anonymize

import (
	"fmt"
	"sort"

	"github.com/charlieyou/cerberus/internal/reviewer"
)

// PeerRecord is the anonymized reviewer output broadcast to later debate rounds.
type PeerRecord struct {
	PeerID            string        `json:"peer_id"`
	Verdict           string        `json:"verdict"`
	Summary           string        `json:"summary"`
	Findings          []PeerFinding `json:"findings"`
	OverallConfidence *float64      `json:"overall_confidence,omitempty"`
	Strategy          *string       `json:"strategy,omitempty"`
	Round             *int          `json:"round,omitempty"`
}

type PeerFinding struct {
	Title          string   `json:"title"`
	Body           string   `json:"body"`
	Severity       *string  `json:"severity"`
	Priority       *int     `json:"priority"`
	FilePath       *string  `json:"file_path"`
	LineStart      *int     `json:"line_start"`
	LineEnd        *int     `json:"line_end"`
	Confidence     *float64 `json:"confidence"`
	Evidence       string   `json:"evidence,omitempty"`
	Recommendation string   `json:"recommendation,omitempty"`
}

// AnonymizePeerBroadcast converts reviewer outputs into peer records for the
// next debate round.
func AnonymizePeerBroadcast(roundOutputs []reviewer.RawReviewerOutput, rosterModelNames []string) ([]PeerRecord, error) {
	if len(roundOutputs) == 0 {
		return []PeerRecord{}, nil
	}

	for i, output := range roundOutputs {
		if output.InstanceID == "" {
			return nil, fmt.Errorf("anonymize reviewer output %d: instance ID is required", i)
		}
		if output.Findings == nil {
			return nil, fmt.Errorf("anonymize reviewer output %s: findings is required", output.InstanceID)
		}
		if output.Verdict == "" {
			return nil, fmt.Errorf("anonymize reviewer output %s: verdict is required", output.InstanceID)
		}
	}

	peerIDs := peerIDsByInstanceID(roundOutputs)
	sorted := latestOutputsByInstanceID(roundOutputs)

	records := make([]PeerRecord, len(sorted))
	for i, output := range sorted {
		peerID := peerIDs[output.InstanceID]
		records[i] = PeerRecord{
			PeerID:            peerID,
			Verdict:           output.Verdict,
			Summary:           Scrub(output.Summary, peerID, rosterModelNames),
			Findings:          scrubFindings(output.Findings, peerID, rosterModelNames),
			OverallConfidence: output.OverallConfidence,
			Strategy:          output.Strategy,
			Round:             output.Round,
		}
	}
	return records, nil
}

func peerIDsByInstanceID(outputs []reviewer.RawReviewerOutput) map[string]string {
	instanceIDs := make([]string, 0, len(outputs))
	seen := make(map[string]bool, len(outputs))
	for _, output := range outputs {
		if !seen[output.InstanceID] {
			seen[output.InstanceID] = true
			instanceIDs = append(instanceIDs, output.InstanceID)
		}
	}
	sort.Strings(instanceIDs)

	peerIDs := make(map[string]string, len(instanceIDs))
	for i, instanceID := range instanceIDs {
		peerIDs[instanceID] = fmt.Sprintf("peer_%d", i+1)
	}
	return peerIDs
}

func latestOutputsByInstanceID(outputs []reviewer.RawReviewerOutput) []reviewer.RawReviewerOutput {
	latest := make(map[string]reviewer.RawReviewerOutput, len(outputs))
	for _, output := range outputs {
		current, ok := latest[output.InstanceID]
		if !ok || roundNumber(output) >= roundNumber(current) {
			latest[output.InstanceID] = output
		}
	}

	instanceIDs := make([]string, 0, len(latest))
	for instanceID := range latest {
		instanceIDs = append(instanceIDs, instanceID)
	}
	sort.Strings(instanceIDs)

	sorted := make([]reviewer.RawReviewerOutput, len(instanceIDs))
	for i, instanceID := range instanceIDs {
		sorted[i] = latest[instanceID]
	}
	return sorted
}

func roundNumber(output reviewer.RawReviewerOutput) int {
	if output.Round == nil {
		return 0
	}
	return *output.Round
}

func scrubFindings(findings []reviewer.RawFinding, peerID string, rosterModelNames []string) []PeerFinding {
	scrubbed := make([]PeerFinding, len(findings))
	for i, finding := range findings {
		filePath := scrubStringPtr(finding.FilePath, peerID, rosterModelNames)
		scrubbed[i] = PeerFinding{
			Title:          Scrub(finding.Title, peerID, rosterModelNames),
			Body:           Scrub(finding.Body, peerID, rosterModelNames),
			Severity:       finding.Severity,
			Priority:       finding.Priority,
			FilePath:       filePath,
			LineStart:      finding.LineStart,
			LineEnd:        finding.LineEnd,
			Confidence:     finding.Confidence,
			Evidence:       Scrub(finding.Evidence, peerID, rosterModelNames),
			Recommendation: Scrub(finding.Recommendation, peerID, rosterModelNames),
		}
	}
	return scrubbed
}

func scrubStringPtr(value *string, peerID string, rosterModelNames []string) *string {
	if value == nil {
		return nil
	}
	scrubbed := Scrub(*value, peerID, rosterModelNames)
	return &scrubbed
}

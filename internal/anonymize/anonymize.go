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

	sorted := append([]reviewer.RawReviewerOutput(nil), roundOutputs...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].InstanceID < sorted[j].InstanceID
	})

	records := make([]PeerRecord, len(roundOutputs))
	for i, output := range sorted {
		peerID := fmt.Sprintf("peer_%d", i+1)
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

func scrubFindings(findings []reviewer.RawFinding, peerID string, rosterModelNames []string) []PeerFinding {
	scrubbed := make([]PeerFinding, len(findings))
	for i, finding := range findings {
		scrubbed[i] = PeerFinding{
			Title:          Scrub(finding.Title, peerID, rosterModelNames),
			Body:           Scrub(finding.Body, peerID, rosterModelNames),
			Severity:       finding.Severity,
			Priority:       finding.Priority,
			FilePath:       finding.FilePath,
			LineStart:      finding.LineStart,
			LineEnd:        finding.LineEnd,
			Confidence:     finding.Confidence,
			Evidence:       Scrub(finding.Evidence, peerID, rosterModelNames),
			Recommendation: Scrub(finding.Recommendation, peerID, rosterModelNames),
		}
	}
	return scrubbed
}

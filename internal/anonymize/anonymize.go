package anonymize

import (
	"fmt"

	"github.com/charlieyou/cerberus/internal/reviewer"
)

// PeerRecord is the anonymized reviewer output broadcast to later debate rounds.
// The T301 skeleton assigns stable peer_N identifiers but intentionally leaves
// text scrubbing to the T302 anonymizer implementation.
type PeerRecord struct {
	PeerID            string                `json:"peer_id"`
	Verdict           string                `json:"verdict"`
	Summary           string                `json:"summary"`
	Findings          []reviewer.RawFinding `json:"findings"`
	OverallConfidence *float64              `json:"overall_confidence,omitempty"`
	Strategy          *string               `json:"strategy,omitempty"`
	Round             *int                  `json:"round,omitempty"`
}

// AnonymizePeerBroadcast converts reviewer outputs into peer records for the
// next debate round. This stub preserves free text verbatim; provider/model
// scrubbing is implemented by T302.
func AnonymizePeerBroadcast(roundOutputs []reviewer.RawReviewerOutput) ([]PeerRecord, error) {
	records := make([]PeerRecord, len(roundOutputs))
	for i, output := range roundOutputs {
		records[i] = PeerRecord{
			PeerID:            fmt.Sprintf("peer_%d", i+1),
			Verdict:           output.Verdict,
			Summary:           output.Summary,
			Findings:          output.Findings,
			OverallConfidence: output.OverallConfidence,
			Strategy:          output.Strategy,
			Round:             output.Round,
		}
	}
	return records, nil
}

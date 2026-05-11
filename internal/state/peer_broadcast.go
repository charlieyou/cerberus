package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

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

func PeerBroadcastPath(runRoot string, iteration, round int) string {
	return filepath.Join(RoundDir(runRoot, iteration, round), "peer-broadcast.json")
}

func WritePeerBroadcast(runRoot string, iteration, round int, records []PeerRecord) error {
	if round < 2 {
		return fmt.Errorf("peer broadcast round must be >= 2")
	}
	sorted := append([]PeerRecord(nil), records...)
	sort.SliceStable(sorted, func(i, j int) bool {
		return sorted[i].PeerID < sorted[j].PeerID
	})
	return writeJSONFile(PeerBroadcastPath(runRoot, iteration, round), sorted)
}

func ReadPeerBroadcast(runRoot string, iteration, round int) ([]PeerRecord, error) {
	data, err := ReadPeerBroadcastBytes(runRoot, iteration, round)
	if err != nil {
		return nil, err
	}
	var records []PeerRecord
	if err := json.Unmarshal(data, &records); err != nil {
		return nil, fmt.Errorf("unmarshal peer broadcast: %w", err)
	}
	return records, nil
}

func ReadPeerBroadcastBytes(runRoot string, iteration, round int) ([]byte, error) {
	data, err := os.ReadFile(PeerBroadcastPath(runRoot, iteration, round))
	if err != nil {
		return nil, fmt.Errorf("read peer broadcast: %w", err)
	}
	return data, nil
}

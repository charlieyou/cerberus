package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const (
	SchemaVersion = 1

	StatusPending  = "pending"
	StatusResolved = "resolved"

	VerdictPass             = "pass"
	VerdictFail             = "fail"
	VerdictRequiresDecision = "requires_decision"

	GateStatePending  = StatusPending
	GateStateResolved = StatusResolved
)

// GateState is persisted as gate-state.json under a run root.
type GateState struct {
	SchemaVersion    int        `json:"schema_version"`
	RunKey           string     `json:"run_key"`
	Host             string     `json:"host"`
	ProjectKey       string     `json:"project_key"`
	SessionID        string     `json:"session_id"`
	TranscriptPath   string     `json:"transcript_path"`
	Status           string     `json:"status"`
	Verdict          *string    `json:"verdict"`
	ResolutionReason string     `json:"resolution_reason,omitempty"`
	CurrentIteration int        `json:"current_iteration"`
	MaxRounds        int        `json:"max_rounds"`
	Debate           bool       `json:"debate"`
	RosterID         string     `json:"roster_id"`
	StartedAt        time.Time  `json:"started_at"`
	EndedAt          *time.Time `json:"ended_at"`
}

// WriteGateState persists the current review gate state.
func WriteGateState(path string, gs *GateState) error {
	if gs == nil {
		return fmt.Errorf("gate state is nil")
	}
	gs.SchemaVersion = SchemaVersion

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create gate state directory: %w", err)
	}

	data, err := json.MarshalIndent(gs, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal gate state: %w", err)
	}
	data = append(data, '\n')

	if err := os.WriteFile(path, data, 0o644); err != nil {
		return fmt.Errorf("write gate state: %w", err)
	}
	return nil
}

// ReadGateState loads the current review gate state.
func ReadGateState(path string) (*GateState, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read gate state: %w", err)
	}

	var gs GateState
	if err := json.Unmarshal(data, &gs); err != nil {
		return nil, fmt.Errorf("unmarshal gate state: %w", err)
	}
	return &gs, nil
}

// MarkResolved transitions a pending gate state to resolved.
func MarkResolved(gs *GateState, verdict string, endedAt time.Time, reasons ...string) {
	if gs == nil {
		return
	}
	gs.Status = StatusResolved
	gs.Verdict = &verdict
	gs.EndedAt = &endedAt
	if len(reasons) > 0 {
		gs.ResolutionReason = reasons[0]
	}
}

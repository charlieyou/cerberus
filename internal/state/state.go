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

// SessionCache is the project-scoped active session seed written by host hooks.
type SessionCache struct {
	SchemaVersion  int       `json:"schema_version"`
	Host           string    `json:"host"`
	ProjectKey     string    `json:"project_key"`
	SessionID      string    `json:"session_id"`
	CodexSessionID string    `json:"codex_session_id,omitempty"`
	RunKey         string    `json:"run_key"`
	TranscriptPath string    `json:"transcript_path"`
	LastSeen       time.Time `json:"last_seen"`
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

// WriteSessionCache persists the active project session cache.
func WriteSessionCache(path string, cache *SessionCache) error {
	if cache == nil {
		return fmt.Errorf("session cache is nil")
	}
	cache.SchemaVersion = SchemaVersion
	if cache.LastSeen.IsZero() {
		cache.LastSeen = time.Now().UTC()
	}
	return writeJSONFile(path, cache)
}

// ReadSessionCache loads the active project session cache.
func ReadSessionCache(path string) (*SessionCache, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read session cache: %w", err)
	}

	var cache SessionCache
	if err := json.Unmarshal(data, &cache); err != nil {
		return nil, fmt.Errorf("unmarshal session cache: %w", err)
	}
	return &cache, nil
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

func writeJSONFile(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}

	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal state file: %w", err)
	}
	data = append(data, '\n')

	if err := os.WriteFile(path, data, 0o644); err != nil {
		return fmt.Errorf("write state file: %w", err)
	}
	return nil
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

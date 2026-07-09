package telemetry

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/charlieyou/cerberus/internal/state"
)

const SchemaVersion = 1

type Tokens struct {
	Input  int `json:"input"`
	Output int `json:"output"`
}

type ReviewerRow struct {
	SchemaVersion     int        `json:"schema_version"`
	ReviewerID        string     `json:"reviewer_id"`
	InstanceIndex     int        `json:"instance_index"`
	Provider          string     `json:"provider"`
	Model             string     `json:"model"`
	Strategy          string     `json:"strategy"`
	PersonaName       *string    `json:"persona_name"`
	Mode              string     `json:"mode"`
	Tokens            Tokens     `json:"tokens"`
	CostUSD           float64    `json:"cost_usd"`
	PeerID            string     `json:"peer_id"`
	Verdict           string     `json:"verdict"`
	OverallConfidence float64    `json:"overall_confidence"`
	Round             int        `json:"round"`
	TimeToFinishMS    int64      `json:"time_to_finish_ms"`
	StartedAt         time.Time  `json:"started_at"`
	EndedAt           *time.Time `json:"ended_at"`
}

type RoundTelemetry struct {
	SchemaVersion int        `json:"schema_version"`
	Round         int        `json:"round"`
	ReviewerCount int        `json:"reviewer_count"`
	ConsensusPct  float64    `json:"consensus_pct"`
	Abstentions   int        `json:"abstentions"`
	KStarEstimate *float64   `json:"k_star_estimate"`
	StartedAt     time.Time  `json:"started_at"`
	EndedAt       *time.Time `json:"ended_at"`
}

type ReviewerSummary struct {
	ReviewerID string  `json:"reviewer_id"`
	Verdict    string  `json:"verdict"`
	Tokens     Tokens  `json:"tokens"`
	CostUSD    float64 `json:"cost_usd"`
}

type IterationTelemetry struct {
	SchemaVersion   int               `json:"schema_version"`
	Iteration       int               `json:"iteration"`
	Rounds          int               `json:"rounds"`
	Verdict         string            `json:"verdict"`
	ReviewerSummary []ReviewerSummary `json:"reviewer_summary"`
	StartedAt       time.Time         `json:"started_at"`
	EndedAt         *time.Time        `json:"ended_at"`
}

type RunTelemetry struct {
	SchemaVersion int        `json:"schema_version"`
	RunKey        string     `json:"run_key"`
	Host          string     `json:"host"`
	Mode          string     `json:"mode"`
	Debate        bool       `json:"debate"`
	Iterations    int        `json:"iterations"`
	TotalRounds   int        `json:"total_rounds"`
	TotalTokens   Tokens     `json:"total_tokens"`
	TotalCostUSD  float64    `json:"total_cost_usd"`
	FinalVerdict  string     `json:"final_verdict"`
	StartedAt     time.Time  `json:"started_at"`
	EndedAt       *time.Time `json:"ended_at"`
}

func WriteReviewerRow(runRoot string, iteration, round int, row *ReviewerRow) error {
	if row == nil {
		return fmt.Errorf("reviewer row is nil")
	}
	row.SchemaVersion = SchemaVersion

	path := filepath.Join(state.ReviewerDir(runRoot, iteration, round, row.ReviewerID), "telemetry.json")
	if err := writeJSON(path, row); err != nil {
		return fmt.Errorf("write reviewer telemetry: %w", err)
	}
	return nil
}

func WriteRoundTelemetry(runRoot string, iteration, round int, telemetry *RoundTelemetry) error {
	if telemetry == nil {
		return fmt.Errorf("round telemetry is nil")
	}
	telemetry.SchemaVersion = SchemaVersion

	path := filepath.Join(state.RoundDir(runRoot, iteration, round), "round-telemetry.json")
	if err := writeJSON(path, telemetry); err != nil {
		return fmt.Errorf("write round telemetry: %w", err)
	}
	return nil
}

func WriteIterationTelemetry(runRoot string, iteration int, telemetry *IterationTelemetry) error {
	if telemetry == nil {
		return fmt.Errorf("iteration telemetry is nil")
	}
	telemetry.SchemaVersion = SchemaVersion

	path := filepath.Join(state.IterationDir(runRoot, iteration), "iteration-telemetry.json")
	if err := writeJSON(path, telemetry); err != nil {
		return fmt.Errorf("write iteration telemetry: %w", err)
	}
	return nil
}

func WriteRunTelemetry(runRoot string, telemetry *RunTelemetry) error {
	if telemetry == nil {
		return fmt.Errorf("run telemetry is nil")
	}
	telemetry.SchemaVersion = SchemaVersion

	path := filepath.Join(runRoot, "run-telemetry.json")
	if err := writeJSON(path, telemetry); err != nil {
		return fmt.Errorf("write run telemetry: %w", err)
	}
	return nil
}

func writeJSON(path string, value any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create telemetry directory: %w", err)
	}

	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal telemetry: %w", err)
	}
	data = append(data, '\n')

	if err := os.WriteFile(path, data, 0o644); err != nil {
		return fmt.Errorf("write telemetry file: %w", err)
	}
	return nil
}

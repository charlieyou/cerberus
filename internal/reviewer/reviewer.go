package reviewer

import "context"

// Request describes one reviewer invocation.
type Request struct {
	ID        string
	Provider  string
	Model     string
	System    []byte
	User      []byte
	Prompt    []byte
	Root      string
	RunRoot   string
	Iteration int
	Round     int
}

// Response contains the canonical JSON emitted by one reviewer.
type Response struct {
	ID     string
	Output []byte
	Parsed *RawReviewerOutput
}

// Spawner starts reviewer work. Prompt bytes are supplied for stdin, not argv.
type Spawner interface {
	Spawn(ctx context.Context, request Request) (Response, error)
}

// RawReviewerOutput is the v1 per-reviewer JSON schema. Verdict is intentionally
// raw PASS/FAIL/NEEDS_WORK; normalization belongs to aggregation.
type RawReviewerOutput struct {
	Findings          []RawFinding `json:"findings"`
	Verdict           string       `json:"verdict"`
	Summary           string       `json:"summary"`
	OverallConfidence *float64     `json:"overall_confidence,omitempty"`
	Strategy          string       `json:"strategy,omitempty"`
	Round             *int         `json:"round,omitempty"`
	PeerResponsesSeen *int         `json:"peer_responses_seen,omitempty"`
}

type RawFinding struct {
	Title      string   `json:"title"`
	Body       string   `json:"body"`
	Priority   *int     `json:"priority"`
	FilePath   *string  `json:"file_path"`
	LineStart  *int     `json:"line_start"`
	LineEnd    *int     `json:"line_end"`
	Confidence *float64 `json:"confidence,omitempty"`
}

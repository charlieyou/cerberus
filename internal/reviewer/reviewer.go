package reviewer

import "context"

// Request describes one reviewer invocation.
type Request struct {
	ID        string
	Provider  string
	Model     string
	Mode      string
	System    []byte
	User      []byte
	Prompt    []byte
	Root      string
	RunRoot   string
	Iteration int
	Round     int
}

// ProviderInvocation describes one provider CLI subprocess invocation.
type ProviderInvocation struct {
	Label              string
	InstanceID         string
	Provider           string
	Model              string
	Mode               string
	System             []byte
	User               []byte
	Root               string
	ClaudeOutputFormat string
	ClaudeModelFlag    bool
}

// ProviderOutput is the raw captured output from one provider CLI subprocess.
type ProviderOutput struct {
	Stdout []byte
	Stderr []byte
}

// Response contains the canonical JSON emitted by one reviewer.
type Response struct {
	ID      string
	Output  []byte
	Parsed  *RawReviewerOutput
	Tokens  Tokens
	CostUSD float64
}

// Spawner starts reviewer work. Prompt bytes are supplied for stdin, not argv.
type Spawner interface {
	Spawn(ctx context.Context, request Request) (Response, error)
}

type Tokens struct {
	Input  int
	Output int
}

// RawReviewerOutput is the v1 per-reviewer JSON schema. Verdict is intentionally
// raw PASS/FAIL/NEEDS_WORK; normalization belongs to aggregation.
type RawReviewerOutput struct {
	Findings          []RawFinding `json:"findings"`
	Verdict           string       `json:"verdict"`
	Summary           string       `json:"summary"`
	OverallConfidence *float64     `json:"overall_confidence"`
	Strategy          *string      `json:"strategy"`
	Round             *int         `json:"round"`
	PeerResponsesSeen []string     `json:"peer_responses_seen"`
	InstanceID        string       `json:"-"`
}

type RawFinding struct {
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

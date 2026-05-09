package reviewer

import "context"

// Request describes one reviewer invocation.
type Request struct {
	ID       string
	Provider string
	Model    string
	Prompt   []byte
}

// Response contains the canonical JSON emitted by one reviewer.
type Response struct {
	ID     string
	Output []byte
}

// Spawner starts reviewer work. Prompt bytes are supplied for stdin, not argv.
type Spawner interface {
	Spawn(ctx context.Context, request Request) (Response, error)
}

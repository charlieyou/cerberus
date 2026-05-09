package orchestrator

import (
	"context"
	"errors"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/reviewer"
)

// Params contains the single-pass review inputs.
type Params struct {
	Prompt    []byte
	Reviewers []ReviewerSlot
}

// ReviewerSlot names one resolved reviewer slot.
type ReviewerSlot struct {
	ID       string
	Provider string
	Model    string
}

// RunSinglePass executes one review round and resolves the gate from reviewer output.
func RunSinglePass(_ context.Context, _ *config.Env, _ Params, _ reviewer.Spawner) error {
	return errors.New("not implemented")
}

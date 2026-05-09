package state

import (
	"context"
	"errors"
	"path/filepath"

	"github.com/charlieyou/cerberus/internal/config"
)

const (
	GateStatePending  = "pending"
	GateStateResolved = "resolved"
)

// GateState is persisted at <state_root>/<project>/<run>/gate-state.json.
type GateState struct {
	Status  string `json:"status"`
	Verdict string `json:"verdict,omitempty"`
}

// GateStatePath returns the canonical gate-state.json path for env.
func GateStatePath(env *config.Env) string {
	if env == nil {
		return "gate-state.json"
	}
	return filepath.Join(env.StateRoot, env.ProjectKey, env.RunKey, "gate-state.json")
}

// WriteGateState persists the current review gate state.
func WriteGateState(_ context.Context, _ *config.Env, _ GateState) error {
	return errors.New("not implemented")
}

// ReadGateState loads the current review gate state.
func ReadGateState(_ context.Context, _ *config.Env) (GateState, error) {
	return GateState{}, errors.New("not implemented")
}

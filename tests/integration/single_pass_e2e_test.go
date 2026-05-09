package integration_test

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/state"
)

func TestSinglePassReviewResolvesStopHookGate(t *testing.T) {
	t.Skip("pending T2xx implementations")

	ctx := context.Background()
	env := &config.Env{
		Host:       "claude",
		StateRoot:  t.TempDir(),
		ProjectKey: "integration-project",
		RunKey:     "single-pass-review",
	}
	params := orchestrator.Params{
		Prompt: []byte("Review this small change."),
		Reviewers: []orchestrator.ReviewerSlot{
			{ID: "claude#1", Provider: "claude", Model: "stub"},
			{ID: "codex#1", Provider: "codex", Model: "stub"},
			{ID: "gemini#1", Provider: "gemini", Model: "stub"},
		},
	}

	if err := orchestrator.RunSinglePass(ctx, env, params, passReviewerStub{env: env}); err != nil {
		t.Fatalf("RunSinglePass failed: %v", err)
	}

	gate, err := state.ReadGateState(ctx, env)
	if err != nil {
		t.Fatalf("ReadGateState failed: %v", err)
	}
	if gate.Status != state.GateStateResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.GateStateResolved)
	}
	if gate.Verdict != "pass" {
		t.Fatalf("gate verdict = %q, want pass", gate.Verdict)
	}
	if code := pollStopHook(ctx, env, 100*time.Millisecond, time.Second); code != 0 {
		t.Fatalf("Stop hook poll exit code = %d, want 0", code)
	}
}

type passReviewerStub struct {
	env *config.Env
}

func (stub passReviewerStub) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	gate, err := state.ReadGateState(ctx, stub.env)
	if err != nil {
		return reviewer.Response{}, fmt.Errorf("read gate state during reviewer spawn: %w", err)
	}
	if gate.Status != state.GateStatePending {
		return reviewer.Response{}, fmt.Errorf("gate status during reviewer spawn = %q, want %q", gate.Status, state.GateStatePending)
	}

	output, err := json.Marshal(map[string]any{
		"reviewer_id": request.ID,
		"verdict":     "pass",
		"confidence":  0.9,
		"findings":    []any{},
	})
	if err != nil {
		return reviewer.Response{}, err
	}
	return reviewer.Response{ID: request.ID, Output: output}, nil
}

func pollStopHook(ctx context.Context, env *config.Env, interval, timeout time.Duration) int {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()

	tick := time.NewTicker(interval)
	defer tick.Stop()

	for {
		gate, err := state.ReadGateState(ctx, env)
		if err == nil && gate.Status == state.GateStateResolved {
			return 0
		}

		select {
		case <-ctx.Done():
			return 1
		case <-deadline.C:
			return 1
		case <-tick.C:
		}
	}
}

package integration_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/hook"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/state"
)

func TestSinglePassReviewResolvesStopHookGate(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	t.Setenv("PATH", filepath.Join(repoRoot, "tests", "mocks")+string(os.PathListSeparator)+os.Getenv("PATH"))

	ctx := context.Background()
	env := &config.Env{
		Host:       "claude",
		Root:       repoRoot,
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

	gate, err := state.ReadGateState(gateStatePath(env))
	if err != nil {
		t.Fatalf("ReadGateState failed: %v", err)
	}
	if gate.Status != state.GateStateResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.GateStateResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != "pass" {
		t.Fatalf("gate verdict = %v, want pass", gate.Verdict)
	}
	if err := hook.PollGateState(gateStatePath(env), 100*time.Millisecond, 5*time.Second); err != nil {
		t.Fatalf("Stop hook poll failed: %v", err)
	}
}

type passReviewerStub struct {
	env *config.Env
}

func (stub passReviewerStub) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	gate, err := state.ReadGateState(gateStatePath(stub.env))
	if err != nil {
		return reviewer.Response{}, fmt.Errorf("read gate state during reviewer spawn: %w", err)
	}
	if gate.Status != state.GateStatePending {
		return reviewer.Response{}, fmt.Errorf("gate status during reviewer spawn = %q, want %q", gate.Status, state.GateStatePending)
	}

	confidence := 0.9
	round := 1
	output, err := json.Marshal(reviewer.RawReviewerOutput{
		Verdict:           "PASS",
		Summary:           "ok",
		OverallConfidence: &confidence,
		Round:             &round,
		Findings:          []reviewer.RawFinding{},
		PeerResponsesSeen: []string{},
	})
	if err != nil {
		return reviewer.Response{}, err
	}
	return reviewer.Response{ID: request.ID, Output: output}, nil
}

func gateStatePath(env *config.Env) string {
	return state.GateStatePath(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey))
}

package orchestrator

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/state"
)

func TestRunSinglePassTransitionsPendingToResolvedPass(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := observingSpawner{t: t, env: env}

	if err := RunSinglePass(context.Background(), env, testParams(), spawner); err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}

	gate := readGate(t, env)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.StatusResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictPass {
		t.Fatalf("gate verdict = %v, want %q", gate.Verdict, state.VerdictPass)
	}
}

func TestRunSinglePassReviewerFailureLeavesGatePending(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	wantErr := errors.New("reviewer failed")

	err := RunSinglePass(context.Background(), env, testParams(), errorSpawner{err: wantErr})
	if !errors.Is(err, wantErr) {
		t.Fatalf("RunSinglePass() error = %v, want %v", err, wantErr)
	}

	gate := readGate(t, env)
	if gate.Status != state.StatusPending {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.StatusPending)
	}
	if gate.Verdict != nil {
		t.Fatalf("gate verdict = %v, want nil", gate.Verdict)
	}
}

func TestRunSinglePassWarnsWhenExistingGateIsPending(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	path := gatePath(env)
	if err := state.WriteGateState(path, &state.GateState{
		RunKey:           env.RunKey,
		Host:             env.Host,
		ProjectKey:       env.ProjectKey,
		Status:           state.StatusPending,
		CurrentIteration: 1,
		MaxRounds:        1,
		RosterID:         "default",
	}); err != nil {
		t.Fatalf("seed gate state: %v", err)
	}

	stderr := captureStderr(t, func() {
		if err := RunSinglePass(context.Background(), env, testParams(), passSpawner{}); err != nil {
			t.Fatalf("RunSinglePass() error = %v", err)
		}
	})

	if !strings.Contains(stderr, "warning: gate-state.json is already pending") {
		t.Fatalf("stderr = %q, want pending gate warning", stderr)
	}
}

func TestRunSinglePassExplicitMissingCLIFailsBeforePendingGate(t *testing.T) {
	env := testEnv(t)
	t.Setenv("PATH", t.TempDir())

	err := RunSinglePass(context.Background(), env, testParams(), passSpawner{})
	if err == nil {
		t.Fatal("RunSinglePass() error = nil, want missing CLI preflight error")
	}
	if !strings.Contains(err.Error(), `provider CLI "claude" is not available on PATH`) {
		t.Fatalf("RunSinglePass() error = %q, want missing CLI preflight", err)
	}
	if _, err := state.ReadGateState(gatePath(env)); err == nil {
		t.Fatal("gate-state.json exists after preflight failure, want no pending gate")
	}
}

func TestRunRoundReturnsOriginalErrorBeforeCancellationNoise(t *testing.T) {
	wantErr := errors.New("reviewer command failed")
	_, err := runRound(context.Background(), []ReviewerSlot{
		{ID: "codex#1", Provider: "codex", Model: "stub"},
		{ID: "claude#1", Provider: "claude", Model: "stub"},
	}, noisyCancelSpawner{err: wantErr}, roundPrompts{})
	if !errors.Is(err, wantErr) {
		t.Fatalf("runRound() error = %v, want original error %v", err, wantErr)
	}
}

type observingSpawner struct {
	t   *testing.T
	env *config.Env
}

func (spawner observingSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	gate := readGate(spawner.t, spawner.env)
	if gate.Status != state.StatusPending {
		return reviewer.Response{}, fmt.Errorf("gate status during spawn = %q, want %q", gate.Status, state.StatusPending)
	}
	return passResponse(request.ID)
}

type passSpawner struct{}

func (passSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	return passResponse(request.ID)
}

type errorSpawner struct {
	err error
}

func (spawner errorSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	return reviewer.Response{}, spawner.err
}

type noisyCancelSpawner struct {
	err error
}

func (spawner noisyCancelSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	if request.ID == "codex#1" {
		return reviewer.Response{}, context.Canceled
	}
	return reviewer.Response{}, spawner.err
}

func passResponse(id string) (reviewer.Response, error) {
	confidence := 0.9
	round := 1
	parsed := &reviewer.RawReviewerOutput{
		Findings:          []reviewer.RawFinding{},
		Verdict:           "PASS",
		Summary:           "ok",
		OverallConfidence: &confidence,
		Strategy:          nil,
		Round:             &round,
		PeerResponsesSeen: []string{},
	}
	output, err := json.Marshal(parsed)
	if err != nil {
		return reviewer.Response{}, err
	}
	return reviewer.Response{ID: id, Output: output, Parsed: parsed}, nil
}

func testEnv(t *testing.T) *config.Env {
	t.Helper()
	return &config.Env{
		Host:       "generic",
		StateRoot:  t.TempDir(),
		ProjectKey: "project",
		RunKey:     "run",
	}
}

func testParams() Params {
	return Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "claude#1", Provider: "claude", Model: "stub"},
			{ID: "codex#1", Provider: "codex", Model: "stub"},
			{ID: "gemini#1", Provider: "gemini", Model: "stub"},
		},
	}
}

func readGate(t *testing.T, env *config.Env) *state.GateState {
	t.Helper()
	gate, err := state.ReadGateState(gatePath(env))
	if err != nil {
		t.Fatalf("ReadGateState() error = %v", err)
	}
	return gate
}

func gatePath(env *config.Env) string {
	return state.GateStatePath(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey))
}

func setMockPath(t *testing.T) {
	t.Helper()
	abs, err := filepath.Abs(filepath.Join("..", "..", "tests", "mocks"))
	if err != nil {
		t.Fatalf("Abs(tests/mocks) error = %v", err)
	}
	t.Setenv("PATH", abs+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stderr
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe() error = %v", err)
	}
	os.Stderr = write
	defer func() {
		os.Stderr = old
	}()

	fn()

	if err := write.Close(); err != nil {
		t.Fatalf("close stderr pipe: %v", err)
	}
	data, err := io.ReadAll(read)
	if err != nil {
		t.Fatalf("read stderr pipe: %v", err)
	}
	return string(data)
}

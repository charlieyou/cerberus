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
	}, noisyCancelSpawner{err: wantErr}, roundPrompts{Root: repoRoot(t)})
	if !errors.Is(err, wantErr) {
		t.Fatalf("runRound() error = %v, want original error %v", err, wantErr)
	}
}

func TestRunSinglePassPassesSlotStrategyAsSystemPrompt(t *testing.T) {
	env := testEnv(t)
	env.Root = promptRoot(t)
	setMockPath(t)
	spawner := systemPromptSpawner{want: "Strategy: falsification-first."}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub", Strategy: "falsification-first"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}
}

func TestRunSinglePassIncludesReviewerTemplateForDefaultSlot(t *testing.T) {
	env := testEnv(t)
	env.Root = promptRoot(t)
	setMockPath(t)
	spawner := promptContentSpawner{
		wantUser:   "reviewer prompt\n\nreview this",
		wantSystem: "",
	}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}
}

func TestRunSinglePassIncludesReviewerTemplateWithStrategy(t *testing.T) {
	env := testEnv(t)
	env.Root = promptRoot(t)
	setMockPath(t)
	spawner := promptContentSpawner{
		wantSystem: "Strategy: falsification-first.",
		wantUser:   "reviewer prompt\n\nreview this",
	}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub", Strategy: "falsification-first"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
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

type systemPromptSpawner struct {
	want string
}

func (spawner systemPromptSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	if !strings.Contains(string(request.System), spawner.want) {
		return reviewer.Response{}, fmt.Errorf("system prompt = %q, want %q", request.System, spawner.want)
	}
	return passResponse(request.ID)
}

type promptContentSpawner struct {
	wantSystem string
	wantUser   string
}

func (spawner promptContentSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	if !strings.Contains(string(request.System), spawner.wantSystem) {
		return reviewer.Response{}, fmt.Errorf("system prompt = %q, want %q", request.System, spawner.wantSystem)
	}
	if got := string(request.User); got != spawner.wantUser {
		return reviewer.Response{}, fmt.Errorf("user prompt = %q, want %q", got, spawner.wantUser)
	}
	return passResponse(request.ID)
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

func promptRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "prompts", "strategies"), 0o755); err != nil {
		t.Fatalf("MkdirAll(strategies) error = %v", err)
	}
	if err := os.MkdirAll(filepath.Join(root, "prompts", "reviewers"), 0o755); err != nil {
		t.Fatalf("MkdirAll(reviewers) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "prompts", "strategies", "falsification-first.md"), []byte("Strategy: falsification-first."), 0o644); err != nil {
		t.Fatalf("WriteFile(strategy) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "prompts", "reviewers", "code.md"), []byte("reviewer prompt"), 0o644); err != nil {
		t.Fatalf("WriteFile(reviewer prompt) error = %v", err)
	}
	return root
}

func testEnv(t *testing.T) *config.Env {
	t.Helper()
	return &config.Env{
		Host:       "generic",
		Root:       repoRoot(t),
		StateRoot:  t.TempDir(),
		ProjectKey: "project",
		RunKey:     "run",
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	return root
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

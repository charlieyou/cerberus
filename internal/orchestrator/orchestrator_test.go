package orchestrator

import (
	"bufio"
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
	"github.com/charlieyou/cerberus/internal/telemetry"
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

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, errorSpawner{err: wantErr})
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
	events := readEventLog(t, env)
	assertEventCount(t, events, telemetry.EventReviewerFailed, 1)
}

func TestStartSinglePassTelemetryFailureResolvesGate(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	if err := os.MkdirAll(filepath.Join(runRoot, "event-log.jsonl"), 0o755); err != nil {
		t.Fatalf("MkdirAll(event-log.jsonl) error = %v", err)
	}

	_, err := StartSinglePass(env, testParams())

	if err == nil || !strings.Contains(err.Error(), "open event log") {
		t.Fatalf("StartSinglePass() error = %v, want open event log", err)
	}
	gate := readGate(t, env)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.StatusResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictRequiresDecision {
		t.Fatalf("gate verdict = %v, want %q", gate.Verdict, state.VerdictRequiresDecision)
	}
	if !strings.Contains(gate.ResolutionReason, "roster selected telemetry failed") {
		t.Fatalf("resolution reason = %q, want telemetry failure", gate.ResolutionReason)
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

func TestRunSinglePassUsesRosterDefaultsWhenParamsOmitted(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := modeSpawner{want: "max"}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt:         []byte("review this"),
		RosterDefaults: RosterDefaults{Mode: "max", MaxRounds: 3},
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}

	gate := readGate(t, env)
	if gate.MaxRounds != 3 {
		t.Fatalf("gate max_rounds = %d, want 3", gate.MaxRounds)
	}
	runTelemetry := readRunTelemetry(t, env)
	if got, want := runTelemetry["mode"], "max"; got != want {
		t.Fatalf("run telemetry mode = %v, want %q", got, want)
	}
}

func TestRunSinglePassCLIParamsOverrideRosterDefaults(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := modeSpawner{want: "smart"}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt:         []byte("review this"),
		RosterDefaults: RosterDefaults{Mode: "max", MaxRounds: 3},
		Mode:           "smart",
		MaxRounds:      1,
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}

	gate := readGate(t, env)
	if gate.MaxRounds != 1 {
		t.Fatalf("gate max_rounds = %d, want 1", gate.MaxRounds)
	}
	runTelemetry := readRunTelemetry(t, env)
	if got, want := runTelemetry["mode"], "smart"; got != want {
		t.Fatalf("run telemetry mode = %v, want %q", got, want)
	}
}

func TestRunSinglePassWritesReviewerRoundAndIterationTelemetry(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := usageSpawner{}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Mode:   "smart",
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "gpt-5.4", Strategy: "falsification-first", InstanceIndex: 1},
			{ID: "claude#2", Provider: "claude", Model: "sonnet", InstanceIndex: 2},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}

	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	row := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "codex#1", "telemetry.json"))
	if got, want := row["reviewer_id"], "codex#1"; got != want {
		t.Fatalf("reviewer_id = %v, want %q", got, want)
	}
	if got, want := row["instance_index"], float64(1); got != want {
		t.Fatalf("instance_index = %v, want %v", got, want)
	}
	if got := row["persona_name"]; got != nil {
		t.Fatalf("persona_name = %v, want nil", got)
	}
	tokens := row["tokens"].(map[string]any)
	if got, want := tokens["input"], float64(10); got != want {
		t.Fatalf("tokens.input = %v, want %v", got, want)
	}
	if got, want := row["cost_usd"], 0.01; got != want {
		t.Fatalf("cost_usd = %v, want %v", got, want)
	}

	roundTelemetry := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "round-1", "round-telemetry.json"))
	if got, want := roundTelemetry["reviewer_count"], float64(2); got != want {
		t.Fatalf("round reviewer_count = %v, want %v", got, want)
	}
	if got, want := roundTelemetry["consensus_pct"], float64(1); got != want {
		t.Fatalf("round consensus_pct = %v, want %v", got, want)
	}

	iterationTelemetry := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "iteration-telemetry.json"))
	summary := iterationTelemetry["reviewer_summary"].([]any)
	if len(summary) != 2 {
		t.Fatalf("reviewer_summary length = %d, want 2", len(summary))
	}
	runTelemetry := readRunTelemetry(t, env)
	totalTokens := runTelemetry["total_tokens"].(map[string]any)
	if got, want := totalTokens["input"], float64(30); got != want {
		t.Fatalf("run total_tokens.input = %v, want %v", got, want)
	}
	if got, want := runTelemetry["total_cost_usd"], 0.03; got != want {
		t.Fatalf("run total_cost_usd = %v, want %v", got, want)
	}

	events := readEventLog(t, env)
	assertEventCount(t, events, telemetry.EventReviewSpawned, 1)
	assertEventCount(t, events, telemetry.EventRosterSelected, 1)
	assertEventCount(t, events, telemetry.EventReviewerSpawned, 2)
	assertEventCount(t, events, telemetry.EventReviewerCompleted, 2)
	assertEventCount(t, events, telemetry.EventReviewRoundComplete, 1)
	assertEventCount(t, events, telemetry.EventReviewResolved, 1)
	rosterEvent := findEvent(t, events, telemetry.EventRosterSelected)
	if got, want := rosterEvent["roster_name"], "default"; got != want {
		t.Fatalf("roster selected roster_name = %v, want %q", got, want)
	}
	if got, want := rosterEvent["reviewer_count"], float64(2); got != want {
		t.Fatalf("roster selected reviewer_count = %v, want %v", got, want)
	}
	for _, event := range events {
		if event["event"] != telemetry.EventReviewerSpawned && event["event"] != telemetry.EventReviewerCompleted {
			continue
		}
		switch event["reviewer_id"] {
		case "codex#1", "claude#2":
		default:
			t.Fatalf("reviewer event reviewer_id = %v, want codex#1 or claude#2", event["reviewer_id"])
		}
		if event["instance_index"] != float64(1) && event["instance_index"] != float64(2) {
			t.Fatalf("reviewer event instance_index = %v, want 1 or 2", event["instance_index"])
		}
	}
	roundEvent := findEvent(t, events, telemetry.EventReviewRoundComplete)
	if got, want := roundEvent["round"], float64(1); got != want {
		t.Fatalf("round_complete round = %v, want %v", got, want)
	}
	if got, want := roundEvent["consensus_pct"], float64(1); got != want {
		t.Fatalf("round_complete consensus_pct = %v, want %v", got, want)
	}
	if got, want := roundEvent["abstentions"], float64(0); got != want {
		t.Fatalf("round_complete abstentions = %v, want %v", got, want)
	}
}

func TestRunSinglePassSlotModeOverridesRuntimeModeForReviewer(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := modeSpawner{want: "fast"}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt:         []byte("review this"),
		RosterDefaults: RosterDefaults{Mode: "max"},
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub", Mode: "fast"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
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
	events := readEventLog(t, env)
	event := findEvent(t, events, telemetry.EventPreflightFailed)
	if got, want := event["stage"], "reviewer"; got != want {
		t.Fatalf("preflight failed stage = %v, want %q", got, want)
	}
	if !strings.Contains(fmt.Sprint(event["error"]), `provider CLI "claude" is not available on PATH`) {
		t.Fatalf("preflight failed error = %v, want missing CLI", event["error"])
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

type modeSpawner struct {
	want string
}

func (spawner modeSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	if request.Mode != spawner.want {
		return reviewer.Response{}, fmt.Errorf("request mode = %q, want %q", request.Mode, spawner.want)
	}
	return passResponse(request.ID)
}

type usageSpawner struct{}

func (usageSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	response, err := passResponse(request.ID)
	if err != nil {
		return reviewer.Response{}, err
	}
	switch request.ID {
	case "codex#1":
		response.Tokens = reviewer.Tokens{Input: 10, Output: 5}
		response.CostUSD = 0.01
	case "claude#2":
		response.Tokens = reviewer.Tokens{Input: 20, Output: 7}
		response.CostUSD = 0.02
	}
	return response, nil
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

func readRunTelemetry(t *testing.T, env *config.Env) map[string]any {
	t.Helper()
	path := filepath.Join(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey), "run-telemetry.json")
	return readJSONFile(t, path)
}

func readEventLog(t *testing.T, env *config.Env) []map[string]any {
	t.Helper()
	path := filepath.Join(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey), "event-log.jsonl")
	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("Open(%s) error = %v", path, err)
	}
	defer file.Close()

	var events []map[string]any
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		var event map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			t.Fatalf("Unmarshal event %q error = %v", scanner.Text(), err)
		}
		events = append(events, event)
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("Scan(%s) error = %v", path, err)
	}
	return events
}

func assertEventCount(t *testing.T, events []map[string]any, eventName string, want int) {
	t.Helper()
	got := 0
	for _, event := range events {
		if event["event"] == eventName {
			got++
		}
	}
	if got != want {
		t.Fatalf("event count for %s = %d, want %d; events = %#v", eventName, got, want, events)
	}
}

func findEvent(t *testing.T, events []map[string]any, eventName string) map[string]any {
	t.Helper()
	for _, event := range events {
		if event["event"] == eventName {
			return event
		}
	}
	t.Fatalf("missing event %s in %#v", eventName, events)
	return nil
}

func readJSONFile(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	var got map[string]any
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("Unmarshal(%s) error = %v", path, err)
	}
	return got
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

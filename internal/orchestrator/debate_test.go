package orchestrator

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/charlieyou/cerberus/internal/anonymize"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/state"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

func TestRunDebateRunsTwoRoundsAndWritesRoundTwoPeerBroadcast(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := &debateRecordingSpawner{}
	anonymizerCalls := 0

	verdict, err := (Orchestrator{
		Env:     env,
		Spawner: spawner,
		AnonymizePeerBroadcast: func(outputs []reviewer.RawReviewerOutput, rosterModelNames []string) ([]anonymize.PeerRecord, error) {
			anonymizerCalls++
			if len(outputs) != 2 {
				t.Fatalf("anonymizer outputs length = %d, want 2", len(outputs))
			}
			if got, want := strings.Join(rosterModelNames, ","), "stub,stub"; got != want {
				t.Fatalf("anonymizer roster models = %q, want %q", got, want)
			}
			if outputs[0].InstanceID != "codex#1" || outputs[1].InstanceID != "codex#2" {
				t.Fatalf("anonymizer instance IDs = %q,%q, want codex#1,codex#2", outputs[0].InstanceID, outputs[1].InstanceID)
			}
			return []anonymize.PeerRecord{
				{PeerID: "peer_1", Verdict: outputs[0].Verdict, Summary: outputs[0].Summary},
				{PeerID: "peer_2", Verdict: outputs[1].Verdict, Summary: outputs[1].Summary},
			}, nil
		},
	}).RunDebate(context.Background(), []ReviewerSlot{
		{ID: "codex#1", Provider: "codex", Model: "stub", InstanceIndex: 1},
		{ID: "codex#2", Provider: "codex", Model: "stub", InstanceIndex: 2},
	}, []byte("review this"), 2)
	if err != nil {
		t.Fatalf("RunDebate() error = %v", err)
	}
	if verdict.Verdict != state.VerdictPass {
		t.Fatalf("verdict = %q, want %q", verdict.Verdict, state.VerdictPass)
	}
	if anonymizerCalls != 1 {
		t.Fatalf("anonymizer calls = %d, want 1", anonymizerCalls)
	}
	sort.Strings(spawner.rounds)
	if got, want := strings.Join(spawner.rounds, ","), "codex#1:1,codex#1:2,codex#2:1,codex#2:2"; got != want {
		t.Fatalf("spawn rounds = %s, want %s", got, want)
	}
	if strings.Contains(spawner.prompts["codex#1:2"], "{{{{PEER_BROADCAST}}}}") ||
		!strings.Contains(spawner.prompts["codex#1:2"], `"peer_id": "peer_1"`) ||
		!strings.Contains(spawner.prompts["codex#1:2"], `"peer_id": "peer_2"`) {
		t.Fatalf("round 2 prompt missing substituted peer broadcast: %q", spawner.prompts["codex#1:2"])
	}

	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	if _, err := os.Stat(filepath.Join(runRoot, "iterations", "1", "round-1", "peer-broadcast.json")); !os.IsNotExist(err) {
		t.Fatalf("round-1 peer-broadcast.json exists or stat error = %v, want not exist", err)
	}
	data, err := os.ReadFile(filepath.Join(runRoot, "iterations", "1", "round-2", "peer-broadcast.json"))
	if err != nil {
		t.Fatalf("ReadFile(round-2 peer-broadcast.json) error = %v", err)
	}
	if !strings.Contains(string(data), `"peer_id": "peer_1"`) || !strings.Contains(string(data), `"peer_id": "peer_2"`) {
		t.Fatalf("peer broadcast = %s, want peer_1 and peer_2", data)
	}

	gate := readGate(t, env)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.StatusResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictPass {
		t.Fatalf("gate verdict = %v, want pass", gate.Verdict)
	}

	events := readEventLog(t, env)
	assertEventCount(t, events, telemetry.EventReviewSpawned, 1)
	assertReviewerEventRoundCount(t, events, telemetry.EventReviewerSpawned, 1, 2)
	assertReviewerEventRoundCount(t, events, telemetry.EventReviewerSpawned, 2, 2)
	assertReviewerEventRoundCount(t, events, telemetry.EventReviewerCompleted, 1, 2)
	assertReviewerEventRoundCount(t, events, telemetry.EventReviewerCompleted, 2, 2)
	assertEventCount(t, events, telemetry.EventDebateRoundStarted, 2)
	assertEventCount(t, events, telemetry.EventDebateRoundCompleted, 2)
	assertEventCount(t, events, telemetry.EventDebatePeerBroadcastWritten, 1)
	broadcastEvent := findEvent(t, events, telemetry.EventDebatePeerBroadcastWritten)
	if broadcastEvent["round"] != float64(2) || !strings.HasSuffix(fmt.Sprint(broadcastEvent["path"]), filepath.Join("round-2", "peer-broadcast.json")) {
		t.Fatalf("peer broadcast event = %#v, want round and path", broadcastEvent)
	}
}

func TestRunDebateRunsPeerRoundWhenRoundOnePasses(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := &verdictByRoundSpawner{verdicts: map[int]string{
		1: "PASS",
		2: "PASS",
	}}

	verdict, err := (Orchestrator{Env: env, Spawner: spawner}).RunDebate(context.Background(), []ReviewerSlot{
		{ID: "codex#1", Provider: "codex", Model: "stub", InstanceIndex: 1},
		{ID: "codex#2", Provider: "codex", Model: "stub", InstanceIndex: 2},
	}, []byte("review this"), 2)
	if err != nil {
		t.Fatalf("RunDebate() error = %v", err)
	}
	if verdict.Verdict != state.VerdictPass {
		t.Fatalf("verdict = %q, want %q", verdict.Verdict, state.VerdictPass)
	}
	if got, want := spawner.roundCalls(2), 2; got != want {
		t.Fatalf("round 2 call count = %d, want %d", got, want)
	}
	if _, err := os.Stat(filepath.Join(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey), "iterations", "1", "round-2", "peer-broadcast.json")); err != nil {
		t.Fatalf("round-2 peer-broadcast.json missing: %v", err)
	}
}

func TestRunDebateRunsAllRoundsWhenVerdictRequiresDecision(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := &verdictByRoundSpawner{verdicts: map[int]string{
		1: "NEEDS_WORK",
		2: "NEEDS_WORK",
		3: "NEEDS_WORK",
	}}

	verdict, err := (Orchestrator{Env: env, Spawner: spawner}).RunDebate(context.Background(), []ReviewerSlot{
		{ID: "codex#1", Provider: "codex", Model: "stub", InstanceIndex: 1},
		{ID: "codex#2", Provider: "codex", Model: "stub", InstanceIndex: 2},
	}, []byte("review this"), 3)
	if err != nil {
		t.Fatalf("RunDebate() error = %v", err)
	}
	if verdict.Verdict != state.VerdictRequiresDecision {
		t.Fatalf("verdict = %q, want %q", verdict.Verdict, state.VerdictRequiresDecision)
	}
	if got, want := spawner.roundCalls(3), 2; got != want {
		t.Fatalf("round 3 call count = %d, want %d", got, want)
	}
	if _, err := os.Stat(filepath.Join(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey), "iterations", "1", "round-3", "peer-broadcast.json")); err != nil {
		t.Fatalf("round-3 peer-broadcast.json missing: %v", err)
	}
}

func TestRunDebateRoundTwoReviewerFailureReturnsError(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := &verdictByRoundSpawner{
		verdicts:    map[int]string{1: "NEEDS_WORK"},
		failRound:   2,
		failMessage: "round two failed",
	}

	_, err := (Orchestrator{Env: env, Spawner: spawner}).RunDebate(context.Background(), []ReviewerSlot{
		{ID: "codex#1", Provider: "codex", Model: "stub", InstanceIndex: 1},
		{ID: "codex#2", Provider: "codex", Model: "stub", InstanceIndex: 2},
	}, []byte("review this"), 3)
	if err == nil || !strings.Contains(err.Error(), "round two failed") {
		t.Fatalf("RunDebate() error = %v, want round two failure", err)
	}
}

func TestStartDebateTelemetryFailureResolvesGate(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	if err := os.MkdirAll(filepath.Join(runRoot, "event-log.jsonl"), 0o755); err != nil {
		t.Fatalf("MkdirAll(event-log.jsonl) error = %v", err)
	}

	_, err := (Orchestrator{Env: env}).StartDebate(Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub", InstanceIndex: 1},
			{ID: "claude#1", Provider: "claude", Model: "stub", InstanceIndex: 1},
		},
	})

	if err == nil || !strings.Contains(err.Error(), "open event log") {
		t.Fatalf("StartDebate() error = %v, want open event log", err)
	}
	gate := readGate(t, env)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.StatusResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictRequiresDecision {
		t.Fatalf("gate verdict = %v, want %q", gate.Verdict, state.VerdictRequiresDecision)
	}
	if !strings.Contains(gate.ResolutionReason, "roster selected telemetry failed") {
		t.Fatalf("resolution reason = %q, want roster telemetry failure", gate.ResolutionReason)
	}
}

func TestStartDebateResetsAttemptScopedArtifacts(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	if err := os.MkdirAll(runRoot, 0o755); err != nil {
		t.Fatalf("MkdirAll(runRoot) error = %v", err)
	}
	if err := os.WriteFile(state.StopMessageMarkerPath(runRoot), []byte(`{"emitted_at":"old"}`), 0o644); err != nil {
		t.Fatalf("write marker: %v", err)
	}
	if err := state.WriteReviewerOutput(runRoot, 1, 2, "old#1", []byte(`{"findings":[],"verdict":"FAIL","summary":"stale"}`)); err != nil {
		t.Fatalf("WriteReviewerOutput() error = %v", err)
	}

	_, err := (Orchestrator{Env: env}).StartDebate(Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub", InstanceIndex: 1},
			{ID: "codex#2", Provider: "codex", Model: "stub", InstanceIndex: 2},
		},
	})
	if err != nil {
		t.Fatalf("StartDebate() error = %v", err)
	}
	if _, err := os.Stat(state.StopMessageMarkerPath(runRoot)); !os.IsNotExist(err) {
		t.Fatalf("marker stat err = %v, want marker removed", err)
	}
	if _, err := os.Stat(state.IterationsDir(runRoot)); !os.IsNotExist(err) {
		t.Fatalf("iterations stat err = %v, want previous iterations removed", err)
	}
}

func assertReviewerEventRoundCount(t *testing.T, events []map[string]any, eventName string, round int, want int) {
	t.Helper()
	got := 0
	for _, event := range events {
		if event["event"] == eventName && event["round"] == float64(round) {
			got++
		}
	}
	if got != want {
		t.Fatalf("%s round %d event count = %d, want %d; events = %#v", eventName, round, got, want, events)
	}
}

type debateRecordingSpawner struct {
	mu      sync.Mutex
	rounds  []string
	prompts map[string]string
}

func (spawner *debateRecordingSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	spawner.mu.Lock()
	defer spawner.mu.Unlock()

	if spawner.prompts == nil {
		spawner.prompts = make(map[string]string)
	}
	key := fmt.Sprintf("%s:%d", request.ID, request.Round)
	spawner.rounds = append(spawner.rounds, key)
	spawner.prompts[key] = string(request.User)

	raw := reviewer.RawReviewerOutput{
		Findings:          []reviewer.RawFinding{},
		Verdict:           "NEEDS_WORK",
		Summary:           "round one needs peer input",
		PeerResponsesSeen: []string{},
	}
	if request.Round == 2 {
		raw.Verdict = "PASS"
		raw.Summary = "resolved after peer input"
		raw.PeerResponsesSeen = []string{"peer_1", "peer_2"}
	}
	round := request.Round
	raw.Round = &round
	confidence := 0.8
	raw.OverallConfidence = &confidence

	output, err := json.Marshal(raw)
	if err != nil {
		return reviewer.Response{}, err
	}
	return reviewer.Response{ID: request.ID, Output: output, Parsed: &raw}, nil
}

type verdictByRoundSpawner struct {
	mu          sync.Mutex
	verdicts    map[int]string
	failRound   int
	failMessage string
	calls       map[int]int
}

func (spawner *verdictByRoundSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	spawner.mu.Lock()
	defer spawner.mu.Unlock()

	if spawner.calls == nil {
		spawner.calls = make(map[int]int)
	}
	spawner.calls[request.Round]++
	if request.Round == spawner.failRound {
		return reviewer.Response{}, fmt.Errorf("%s", spawner.failMessage)
	}

	verdict := spawner.verdicts[request.Round]
	if verdict == "" {
		verdict = "PASS"
	}
	round := request.Round
	raw := reviewer.RawReviewerOutput{
		Findings: []reviewer.RawFinding{},
		Verdict:  verdict,
		Summary:  "same reviewer output",
		Round:    &round,
	}
	output, err := json.Marshal(raw)
	if err != nil {
		return reviewer.Response{}, err
	}
	return reviewer.Response{ID: request.ID, Output: output, Parsed: &raw}, nil
}

func (spawner *verdictByRoundSpawner) roundCalls(round int) int {
	spawner.mu.Lock()
	defer spawner.mu.Unlock()
	return spawner.calls[round]
}

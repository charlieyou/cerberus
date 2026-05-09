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
	if !strings.Contains(spawner.prompts["codex#1:2"], "{{{{PEER_BROADCAST}}}}") {
		t.Fatalf("round 2 prompt missing peer broadcast marker: %q", spawner.prompts["codex#1:2"])
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
	assertReviewerEventRoundCount(t, events, telemetry.EventReviewerSpawned, 1, 2)
	assertReviewerEventRoundCount(t, events, telemetry.EventReviewerSpawned, 2, 2)
	assertReviewerEventRoundCount(t, events, telemetry.EventReviewerCompleted, 1, 2)
	assertReviewerEventRoundCount(t, events, telemetry.EventReviewerCompleted, 2, 2)
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

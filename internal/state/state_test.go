package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestGateStateRoundTrips(t *testing.T) {
	startedAt := time.Date(2026, 5, 8, 13, 0, 0, 0, time.UTC)
	gs := &GateState{
		SchemaVersion:    SchemaVersion,
		RunKey:           "run-key",
		Host:             "codex",
		ProjectKey:       "project-key",
		SessionID:        "session-id",
		TranscriptPath:   "/tmp/transcript.jsonl",
		Status:           StatusPending,
		Verdict:          nil,
		CurrentIteration: 1,
		MaxRounds:        3,
		Debate:           false,
		RosterID:         "default",
		StartedAt:        startedAt,
		EndedAt:          nil,
	}

	path := filepath.Join(t.TempDir(), "gate-state.json")
	if err := WriteGateState(path, gs); err != nil {
		t.Fatalf("WriteGateState() returned error: %v", err)
	}

	got, err := ReadGateState(path)
	if err != nil {
		t.Fatalf("ReadGateState() returned error: %v", err)
	}
	if !reflect.DeepEqual(got, gs) {
		t.Fatalf("ReadGateState() = %#v, want %#v", got, gs)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read written gate state: %v", err)
	}
	assertJSONKeyOrder(t, data, []string{
		"schema_version",
		"run_key",
		"host",
		"project_key",
		"session_id",
		"transcript_path",
		"status",
		"verdict",
		"current_iteration",
		"max_rounds",
		"debate",
		"roster_id",
		"started_at",
		"ended_at",
	})
}

func TestMarkResolved(t *testing.T) {
	startedAt := time.Date(2026, 5, 8, 13, 0, 0, 0, time.UTC)
	endedAt := time.Date(2026, 5, 8, 13, 14, 0, 0, time.UTC)
	gs := &GateState{
		SchemaVersion:    SchemaVersion,
		RunKey:           "run-key",
		Host:             "codex",
		ProjectKey:       "project-key",
		SessionID:        "session-id",
		Status:           StatusPending,
		CurrentIteration: 1,
		MaxRounds:        3,
		RosterID:         "default",
		StartedAt:        startedAt,
	}

	MarkResolved(gs, VerdictRequiresDecision, endedAt, "manual override")

	if gs.Status != StatusResolved {
		t.Fatalf("Status = %q, want %q", gs.Status, StatusResolved)
	}
	if gs.Verdict == nil || *gs.Verdict != VerdictRequiresDecision {
		t.Fatalf("Verdict = %v, want %q", gs.Verdict, VerdictRequiresDecision)
	}
	if gs.EndedAt == nil || !gs.EndedAt.Equal(endedAt) {
		t.Fatalf("EndedAt = %v, want %v", gs.EndedAt, endedAt)
	}
	if gs.ResolutionReason != "manual override" {
		t.Fatalf("ResolutionReason = %q, want manual override", gs.ResolutionReason)
	}

	data, err := json.Marshal(gs)
	if err != nil {
		t.Fatalf("json.Marshal() returned error: %v", err)
	}
	if !strings.Contains(string(data), `"verdict":"requires_decision"`) {
		t.Fatalf("serialized gate state = %s, want resolved verdict", data)
	}
	if !strings.Contains(string(data), `"resolution_reason":"manual override"`) {
		t.Fatalf("serialized gate state = %s, want resolution reason", data)
	}
}

func TestPathHelpers(t *testing.T) {
	runRoot := RunDir("/state-root", "project-key", "run-key")
	if got, want := runRoot, filepath.Join("/state-root", "project-key", "run-key"); got != want {
		t.Fatalf("RunDir() = %q, want %q", got, want)
	}
	if got, want := GateStatePath(runRoot), filepath.Join(runRoot, "gate-state.json"); got != want {
		t.Fatalf("GateStatePath() = %q, want %q", got, want)
	}
	if got, want := IterationDir(runRoot, 1), filepath.Join(runRoot, "iterations", "1"); got != want {
		t.Fatalf("IterationDir() = %q, want %q", got, want)
	}
	if got, want := RoundDir(runRoot, 1, 1), filepath.Join(runRoot, "iterations", "1", "round-1"); got != want {
		t.Fatalf("RoundDir() = %q, want %q", got, want)
	}
	if got, want := ReviewerDir(runRoot, 1, 1, "codex#1"), filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "codex#1"); got != want {
		t.Fatalf("ReviewerDir() = %q, want %q", got, want)
	}
}

func TestEnsureRunDirAndWriteReviewerOutput(t *testing.T) {
	runRoot := filepath.Join(t.TempDir(), "project-key", "run-key")
	if err := EnsureRunDir(runRoot); err != nil {
		t.Fatalf("EnsureRunDir() returned error: %v", err)
	}
	if stat, err := os.Stat(runRoot); err != nil {
		t.Fatalf("stat run root: %v", err)
	} else if !stat.IsDir() {
		t.Fatalf("run root is not a directory")
	}

	output := []byte(`{"verdict":"pass"}`)
	if err := WriteReviewerOutput(runRoot, 1, 1, "codex#1", output); err != nil {
		t.Fatalf("WriteReviewerOutput() returned error: %v", err)
	}
	path := filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "codex#1", "output.json")
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read reviewer output: %v", err)
	}
	if string(got) != string(output) {
		t.Fatalf("reviewer output = %q, want %q", got, output)
	}
}

func assertJSONKeyOrder(t *testing.T, data []byte, keys []string) {
	t.Helper()

	last := -1
	for _, key := range keys {
		index := strings.Index(string(data), `"`+key+`"`)
		if index == -1 {
			t.Fatalf("written JSON is missing key %q: %s", key, data)
		}
		if index <= last {
			t.Fatalf("key %q appears out of order in JSON: %s", key, data)
		}
		last = index
	}
}

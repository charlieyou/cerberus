package telemetry

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestWriteReviewerRowUsesReviewerIDAndInstanceIndex(t *testing.T) {
	runRoot := t.TempDir()
	startedAt := time.Date(2026, 5, 8, 13, 0, 0, 0, time.UTC)
	endedAt := time.Date(2026, 5, 8, 13, 0, 45, 0, time.UTC)
	row := &ReviewerRow{
		ReviewerID:        "codex#2",
		InstanceIndex:     2,
		Provider:          "codex",
		Model:             "gpt-5.4",
		Strategy:          "falsification-first",
		PersonaName:       nil,
		Mode:              "smart",
		Tokens:            Tokens{Input: 1234, Output: 567},
		CostUSD:           0.123,
		PeerID:            "peer_2",
		Verdict:           "fail",
		OverallConfidence: 0.75,
		Round:             1,
		TimeToFinishMS:    45123,
		StartedAt:         startedAt,
		EndedAt:           &endedAt,
	}

	if err := WriteReviewerRow(runRoot, 1, 1, row); err != nil {
		t.Fatalf("WriteReviewerRow() returned error: %v", err)
	}

	path := filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "codex#2", "telemetry.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read reviewer telemetry: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal reviewer telemetry: %v", err)
	}
	if got["reviewer_id"] != "codex#2" {
		t.Fatalf("reviewer_id = %v, want codex#2", got["reviewer_id"])
	}
	if got["instance_index"] != float64(2) {
		t.Fatalf("instance_index = %v, want 2", got["instance_index"])
	}
	assertJSONKeyOrder(t, data, []string{
		"schema_version",
		"reviewer_id",
		"instance_index",
		"provider",
		"model",
		"strategy",
		"persona_name",
		"mode",
		"tokens",
		"input",
		"output",
		"cost_usd",
		"peer_id",
		"verdict",
		"overall_confidence",
		"round",
		"time_to_finish_ms",
		"started_at",
		"ended_at",
	})
}

func TestWriteEventAppendsOneJSONLinePerCall(t *testing.T) {
	runRoot := t.TempDir()
	firstAt := time.Date(2026, 5, 8, 13, 0, 0, 0, time.UTC)
	secondAt := time.Date(2026, 5, 8, 13, 1, 0, 0, time.UTC)

	if err := WriteEvent(runRoot, Event{
		Event:     EventBuildStarted,
		Timestamp: firstAt,
		Payload:   map[string]any{"run_key": "run-1"},
	}); err != nil {
		t.Fatalf("WriteEvent(first) returned error: %v", err)
	}
	if err := WriteEvent(runRoot, Event{
		Event:     EventBuildCompleted,
		Timestamp: secondAt,
		Payload:   map[string]any{"run_key": "run-1"},
	}); err != nil {
		t.Fatalf("WriteEvent(second) returned error: %v", err)
	}

	events := readEventLog(t, filepath.Join(runRoot, "event-log.jsonl"))
	if len(events) != 2 {
		t.Fatalf("event count = %d, want 2", len(events))
	}
	if events[0].Event != EventBuildStarted {
		t.Fatalf("first event = %q, want %q", events[0].Event, EventBuildStarted)
	}
	if events[1].Event != EventBuildCompleted {
		t.Fatalf("second event = %q, want %q", events[1].Event, EventBuildCompleted)
	}

	firstLine := readEventLine(t, filepath.Join(runRoot, "event-log.jsonl"))
	if _, ok := firstLine["payload"]; ok {
		t.Fatalf("event line contains nested payload key: %#v", firstLine)
	}
	if firstLine["run_key"] != "run-1" {
		t.Fatalf("run_key = %v, want run-1", firstLine["run_key"])
	}
	if firstLine["event"] != EventBuildStarted {
		t.Fatalf("event = %v, want %s", firstLine["event"], EventBuildStarted)
	}
}

func TestWriteEventConcurrentAppendsDistinctLines(t *testing.T) {
	runRoot := t.TempDir()
	var wg sync.WaitGroup

	for _, eventName := range []string{EventReviewerStarted, EventReviewerCompleted, EventReviewerFailed} {
		wg.Add(1)
		go func(eventName string) {
			defer wg.Done()
			if err := WriteEvent(runRoot, Event{
				Event:     eventName,
				Timestamp: time.Date(2026, 5, 8, 13, 0, 0, 0, time.UTC),
				Payload:   map[string]any{"reviewer_id": eventName},
			}); err != nil {
				t.Errorf("WriteEvent(%q) returned error: %v", eventName, err)
			}
		}(eventName)
	}
	wg.Wait()

	events := readEventLog(t, filepath.Join(runRoot, "event-log.jsonl"))
	if len(events) != 3 {
		t.Fatalf("event count = %d, want 3", len(events))
	}

	seen := map[string]bool{}
	for _, event := range events {
		seen[event.Event] = true
	}
	for _, eventName := range []string{EventReviewerStarted, EventReviewerCompleted, EventReviewerFailed} {
		if !seen[eventName] {
			t.Fatalf("missing event %q in %#v", eventName, events)
		}
	}
}

func TestTelemetryWritersUsePlanPathsAndKeys(t *testing.T) {
	runRoot := t.TempDir()
	startedAt := time.Date(2026, 5, 8, 13, 0, 0, 0, time.UTC)
	endedAt := time.Date(2026, 5, 8, 13, 5, 0, 0, time.UTC)

	if err := WriteRoundTelemetry(runRoot, 1, 2, &RoundTelemetry{
		Round:         2,
		ReviewerCount: 4,
		ConsensusPct:  0.75,
		Abstentions:   0,
		KStarEstimate: nil,
		StartedAt:     startedAt,
		EndedAt:       &endedAt,
	}); err != nil {
		t.Fatalf("WriteRoundTelemetry() returned error: %v", err)
	}
	assertJSONFileKeys(t, filepath.Join(runRoot, "iterations", "1", "round-2", "round-telemetry.json"), []string{
		"schema_version",
		"round",
		"reviewer_count",
		"consensus_pct",
		"abstentions",
		"k_star_estimate",
		"started_at",
		"ended_at",
	})

	if err := WriteIterationTelemetry(runRoot, 1, &IterationTelemetry{
		Iteration: 1,
		Rounds:    2,
		Verdict:   "pass",
		ReviewerSummary: []ReviewerSummary{{
			ReviewerID: "codex#1",
			Verdict:    "pass",
			Tokens:     Tokens{Input: 1000, Output: 400},
			CostUSD:    0.10,
		}},
		StartedAt: startedAt,
		EndedAt:   &endedAt,
	}); err != nil {
		t.Fatalf("WriteIterationTelemetry() returned error: %v", err)
	}
	assertJSONFileKeys(t, filepath.Join(runRoot, "iterations", "1", "iteration-telemetry.json"), []string{
		"schema_version",
		"iteration",
		"rounds",
		"verdict",
		"reviewer_summary",
		"reviewer_id",
		"tokens",
		"input",
		"output",
		"cost_usd",
		"started_at",
		"ended_at",
	})

	if err := WriteRunTelemetry(runRoot, &RunTelemetry{
		RunKey:       "run-key",
		Host:         "claude",
		Mode:         "smart",
		RosterID:     "default",
		Debate:       false,
		Iterations:   1,
		TotalRounds:  1,
		TotalTokens:  Tokens{Input: 4000, Output: 1500},
		TotalCostUSD: 0.45,
		FinalVerdict: "pass",
		StartedAt:    startedAt,
		EndedAt:      &endedAt,
	}); err != nil {
		t.Fatalf("WriteRunTelemetry() returned error: %v", err)
	}
	assertJSONFileKeys(t, filepath.Join(runRoot, "run-telemetry.json"), []string{
		"schema_version",
		"run_key",
		"host",
		"mode",
		"roster_id",
		"debate",
		"iterations",
		"total_rounds",
		"total_tokens",
		"input",
		"output",
		"total_cost_usd",
		"final_verdict",
		"started_at",
		"ended_at",
	})
}

func readEventLog(t *testing.T, path string) []Event {
	t.Helper()

	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("open event log: %v", err)
	}
	defer file.Close()

	var events []Event
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "" {
			t.Fatalf("event log contains blank line")
		}

		var event Event
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("unmarshal event line %q: %v", line, err)
		}
		events = append(events, event)
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan event log: %v", err)
	}
	return events
}

func readEventLine(t *testing.T, path string) map[string]any {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read event log: %v", err)
	}
	line, _, _ := strings.Cut(string(data), "\n")

	var event map[string]any
	if err := json.Unmarshal([]byte(line), &event); err != nil {
		t.Fatalf("unmarshal first event line: %v", err)
	}
	return event
}

func assertJSONFileKeys(t *testing.T, path string, keys []string) {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	assertJSONKeyOrder(t, data, keys)
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

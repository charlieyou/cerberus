package hook

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/state"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

func TestCodexHandlersAcceptFixturePayloadsAndEmitAllowedEvent(t *testing.T) {
	for _, tc := range []struct {
		name    string
		fixture string
		handle  func([]byte, *config.Env) error
	}{
		{name: "session-start", fixture: "hook-payload-session-start.json", handle: HandleCodexSessionStart},
		{name: "prompt-submit", fixture: "hook-payload-prompt-submit.json", handle: HandleCodexPromptSubmit},
		{name: "stop", fixture: "hook-payload-stop.json", handle: HandleCodexStop},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload := readCodexFixture(t, tc.fixture)
			env := &config.Env{Host: "codex", StateRoot: t.TempDir()}

			if err := tc.handle(payload, env); err != nil {
				t.Fatalf("%s handler returned error: %v", tc.name, err)
			}

			event := readSingleCodexEvent(t, filepath.Join(env.StateRoot, "codex-fixture-project", "codex-fixture-session", "event-log.jsonl"))
			if event["event"] != telemetry.EventHookAllowed {
				t.Fatalf("event = %v, want %s", event["event"], telemetry.EventHookAllowed)
			}
			if tc.name != "stop" && event["session_id"] != "codex-fixture-session" {
				t.Fatalf("session_id = %v, want codex-fixture-session", event["session_id"])
			}
		})
	}
}

func TestDecodeCodexPayloadReportsMalformedField(t *testing.T) {
	_, err := decodeCodexPayload([]byte(`{"session_id":123}`))
	if err == nil {
		t.Fatal("decodeCodexPayload() error = nil, want field parse error")
	}
	if got := err.Error(); !strings.Contains(got, "session_id") {
		t.Fatalf("decodeCodexPayload() error = %q, want session_id", got)
	}
	if strings.Contains(err.Error(), "\n") {
		t.Fatalf("decodeCodexPayload() error contains newline: %q", err)
	}
}

func TestHandleCodexStopPollsUntilGateStateResolves(t *testing.T) {
	payload := readCodexFixture(t, "hook-payload-stop.json")
	env := &config.Env{Host: "codex", StateRoot: t.TempDir()}
	gatePath := filepath.Join(env.StateRoot, "codex-fixture-project", "codex-fixture-session", "gate-state.json")
	if err := state.WriteGateState(gatePath, &state.GateState{Status: state.StatusPending}); err != nil {
		t.Fatalf("seed pending gate: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- handleCodexStopWithWait(payload, env, 10*time.Millisecond, time.Second)
	}()

	time.Sleep(30 * time.Millisecond)
	verdict := state.VerdictPass
	if err := state.WriteGateState(gatePath, &state.GateState{Status: state.StatusResolved, Verdict: &verdict}); err != nil {
		t.Fatalf("write resolved gate: %v", err)
	}

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("HandleCodexStop() error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("HandleCodexStop() did not return after gate resolved")
	}

	events := readCodexEvents(t, filepath.Join(env.StateRoot, "codex-fixture-project", "codex-fixture-session", "event-log.jsonl"))
	if len(events) != 2 {
		t.Fatalf("event count = %d, want blocked and allowed", len(events))
	}
	if events[0]["event"] != telemetry.EventHookBlocked || events[1]["event"] != telemetry.EventHookAllowed {
		t.Fatalf("events = %#v, want blocked then allowed", events)
	}
}

func TestHandleCodexStopReturnsErrorAfterMaxWait(t *testing.T) {
	payload := readCodexFixture(t, "hook-payload-stop.json")
	env := &config.Env{Host: "codex", StateRoot: t.TempDir()}
	gatePath := filepath.Join(env.StateRoot, "codex-fixture-project", "codex-fixture-session", "gate-state.json")
	if err := state.WriteGateState(gatePath, &state.GateState{Status: state.StatusPending}); err != nil {
		t.Fatalf("seed pending gate: %v", err)
	}

	err := handleCodexStopWithWait(payload, env, 10*time.Millisecond, 30*time.Millisecond)
	if err == nil {
		t.Fatal("HandleCodexStop() error = nil, want timeout")
	}
	if !strings.Contains(err.Error(), "timed out waiting for gate state") {
		t.Fatalf("HandleCodexStop() error = %q, want timeout", err)
	}
	if strings.Contains(err.Error(), "\n") {
		t.Fatalf("HandleCodexStop() error contains newline: %q", err)
	}
}

func TestHandleCodexStopReturnsErrorForMalformedGateState(t *testing.T) {
	payload := readCodexFixture(t, "hook-payload-stop.json")
	env := &config.Env{Host: "codex", StateRoot: t.TempDir()}
	gatePath := filepath.Join(env.StateRoot, "codex-fixture-project", "codex-fixture-session", "gate-state.json")
	if err := os.MkdirAll(filepath.Dir(gatePath), 0o755); err != nil {
		t.Fatalf("create gate dir: %v", err)
	}
	if err := os.WriteFile(gatePath, []byte(`{"status":`), 0o644); err != nil {
		t.Fatalf("write malformed gate: %v", err)
	}

	err := handleCodexStopWithWait(payload, env, 10*time.Millisecond, 30*time.Millisecond)
	if err == nil {
		t.Fatal("HandleCodexStop() error = nil, want malformed gate error")
	}
	if !strings.Contains(err.Error(), "timed out waiting for readable gate state") {
		t.Fatalf("HandleCodexStop() error = %q, want readable gate timeout", err)
	}
	if strings.Contains(err.Error(), "\n") {
		t.Fatalf("HandleCodexStop() error contains newline: %q", err)
	}
}

func readCodexFixture(t *testing.T, name string) []byte {
	t.Helper()

	path := filepath.Join("..", "..", "tests", "fixtures", "codex", name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return data
}

func readSingleCodexEvent(t *testing.T, path string) map[string]any {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read event log: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 1 {
		t.Fatalf("event log line count = %d, want 1\n%s", len(lines), data)
	}
	var event map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &event); err != nil {
		t.Fatalf("unmarshal event: %v", err)
	}
	return event
}

func readCodexEvents(t *testing.T, path string) []map[string]any {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read event log: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	events := make([]map[string]any, 0, len(lines))
	for _, line := range lines {
		var event map[string]any
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("unmarshal event: %v", err)
		}
		events = append(events, event)
	}
	return events
}

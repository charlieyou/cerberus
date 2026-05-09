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
)

func TestPollGateStateReturnsWhenResolvedWithinMaxWait(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gate-state.json")
	if err := state.WriteGateState(path, &state.GateState{Status: state.StatusPending}); err != nil {
		t.Fatalf("seed pending gate: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- PollGateState(path, 10*time.Millisecond, time.Second)
	}()

	time.Sleep(30 * time.Millisecond)
	verdict := state.VerdictPass
	if err := state.WriteGateState(path, &state.GateState{Status: state.StatusResolved, Verdict: &verdict}); err != nil {
		t.Fatalf("write resolved gate: %v", err)
	}

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("PollGateState() error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("PollGateState() did not return after gate resolved")
	}
}

func TestPollGateStateReturnsErrorAfterMaxWait(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gate-state.json")
	if err := state.WriteGateState(path, &state.GateState{Status: state.StatusPending}); err != nil {
		t.Fatalf("seed pending gate: %v", err)
	}

	err := PollGateState(path, 10*time.Millisecond, 30*time.Millisecond)
	if err == nil {
		t.Fatal("PollGateState() error = nil, want timeout")
	}
	if !strings.Contains(err.Error(), "timed out waiting for gate state") {
		t.Fatalf("PollGateState() error = %q, want timeout message", err)
	}
}

func TestHandleClaudeSessionStartInitializesRunFromStdinPayload(t *testing.T) {
	env := &config.Env{
		Host:       "generic",
		StateRoot:  t.TempDir(),
		ProjectKey: "project",
	}
	payload := []byte(`{"session_id":"session-123","transcript_path":"/tmp/transcript.jsonl"}`)

	if err := HandleClaudeSessionStart(payload, env); err != nil {
		t.Fatalf("HandleClaudeSessionStart() error = %v", err)
	}

	data, err := os.ReadFile(filepath.Join(env.StateRoot, env.ProjectKey, "session-123", "session.json"))
	if err != nil {
		t.Fatalf("read session.json: %v", err)
	}
	var got map[string]string
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal session.json: %v", err)
	}
	if got["run_key"] != "session-123" || got["transcript_path"] != "/tmp/transcript.jsonl" {
		t.Fatalf("session.json = %#v, want run key and transcript path from stdin payload", got)
	}
}

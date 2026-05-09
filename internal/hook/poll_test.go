package hook

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/host"
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

func TestPollGateStateRetriesTransientUnreadableState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gate-state.json")
	if err := os.WriteFile(path, []byte(`{"status":`), 0o644); err != nil {
		t.Fatalf("write malformed gate: %v", err)
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
		t.Fatal("PollGateState() did not return after malformed gate was replaced")
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

func TestHandleClaudeSessionStartPayloadOverridesStaleEnvRunIdentity(t *testing.T) {
	env := &config.Env{
		Host:           "generic",
		StateRoot:      t.TempDir(),
		ProjectKey:     "project",
		RunKey:         "stale-run",
		SessionID:      "stale-session",
		TranscriptPath: "/tmp/stale.jsonl",
	}
	payload := []byte(`{"session_id":"current-session","transcript_path":"/tmp/current.jsonl"}`)

	if err := HandleClaudeSessionStart(payload, env); err != nil {
		t.Fatalf("HandleClaudeSessionStart() error = %v", err)
	}

	currentData, err := os.ReadFile(filepath.Join(env.StateRoot, env.ProjectKey, "current-session", "session.json"))
	if err != nil {
		t.Fatalf("read current session.json: %v", err)
	}
	var got map[string]string
	if err := json.Unmarshal(currentData, &got); err != nil {
		t.Fatalf("unmarshal current session.json: %v", err)
	}
	if got["run_key"] != "current-session" || got["session_id"] != "current-session" || got["transcript_path"] != "/tmp/current.jsonl" {
		t.Fatalf("current session.json = %#v, want payload identity to override stale env", got)
	}
	if _, err := os.Stat(filepath.Join(env.StateRoot, env.ProjectKey, "stale-run", "session.json")); !os.IsNotExist(err) {
		t.Fatalf("stale env run was used; stat err = %v", err)
	}
}

func TestHandleClaudeSessionStartPayloadCWDOverridesProcessCWDAndStaleProjectKey(t *testing.T) {
	pluginRoot := t.TempDir()
	projectRoot := t.TempDir()
	if err := os.Mkdir(filepath.Join(projectRoot, ".git"), 0o755); err != nil {
		t.Fatalf("create git marker: %v", err)
	}
	projectSubdir := filepath.Join(projectRoot, "pkg")
	if err := os.MkdirAll(projectSubdir, 0o755); err != nil {
		t.Fatalf("create project subdir: %v", err)
	}
	oldWD, err := os.Getwd()
	if err != nil {
		t.Fatalf("os.Getwd() error = %v", err)
	}
	if err := os.Chdir(pluginRoot); err != nil {
		t.Fatalf("os.Chdir(pluginRoot) error = %v", err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(oldWD); err != nil {
			t.Fatalf("restore working directory: %v", err)
		}
	})

	env := &config.Env{
		Host:       "generic",
		StateRoot:  t.TempDir(),
		ProjectKey: "stale-project",
		RunKey:     "stale-run",
	}
	payload := []byte(`{"session_id":"current-session","cwd":` + strconv.Quote(projectSubdir) + `}`)

	if err := HandleClaudeSessionStart(payload, env); err != nil {
		t.Fatalf("HandleClaudeSessionStart() error = %v", err)
	}

	projectKey, err := host.ProjectKeyFromDir(projectSubdir)
	if err != nil {
		t.Fatalf("ProjectKeyFromDir() error = %v", err)
	}
	if _, err := os.Stat(filepath.Join(env.StateRoot, projectKey, "current-session", "session.json")); err != nil {
		t.Fatalf("payload cwd run was not initialized: %v", err)
	}
	if _, err := os.Stat(filepath.Join(env.StateRoot, "stale-project", "current-session", "session.json")); !os.IsNotExist(err) {
		t.Fatalf("stale project key was used; stat err = %v", err)
	}
}

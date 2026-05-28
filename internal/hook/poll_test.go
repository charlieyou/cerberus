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
	"github.com/charlieyou/cerberus/internal/reviewer"
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
	cache, err := state.ReadSessionCache(state.SessionCachePath(env.StateRoot, env.ProjectKey))
	if err != nil {
		t.Fatalf("ReadSessionCache() error = %v", err)
	}
	if cache.RunKey != "session-123" || cache.SessionID != "session-123" || cache.TranscriptPath != "/tmp/transcript.jsonl" {
		t.Fatalf("session cache = %#v, want run key and transcript path from stdin payload", cache)
	}
}

func TestHandleClaudeStopResponseEmitsFeedbackText(t *testing.T) {
	env := &config.Env{
		Host:       "claude",
		StateRoot:  t.TempDir(),
		ProjectKey: "project",
	}
	payload := []byte(`{"session_id":"session-123","transcript_path":"/tmp/transcript.jsonl"}`)
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, "session-123")
	if err := state.WriteReviewerOutput(runRoot, 1, 1, "claude#1", mustReviewerOutput(t, reviewer.RawReviewerOutput{
		Verdict: "PASS",
		Summary: "No blocking issues found.",
	})); err != nil {
		t.Fatalf("WriteReviewerOutput() error = %v", err)
	}
	verdict := state.VerdictPass
	if err := state.WriteGateState(state.GateStatePath(runRoot), &state.GateState{Status: state.StatusResolved, Verdict: &verdict}); err != nil {
		t.Fatalf("seed resolved gate: %v", err)
	}

	response, err := HandleClaudeStopResponse(payload, env)
	if err != nil {
		t.Fatalf("HandleClaudeStopResponse() error = %v", err)
	}
	if strings.HasPrefix(strings.TrimSpace(response), "{") {
		t.Fatalf("response = %q, want plain Stop-hook feedback text for Claude", response)
	}
	if !strings.Contains(response, "## Review Complete") || !strings.Contains(response, "Please provide a brief summary") {
		t.Fatalf("response = %q, want review-complete prompt", response)
	}
}

func TestReadReviewerOutputsPrefersPostReviewDedupOutput(t *testing.T) {
	runRoot := t.TempDir()
	priority := 1
	if err := state.WriteReviewerOutput(runRoot, 1, 1, "claude#1", mustReviewerOutput(t, reviewer.RawReviewerOutput{
		Findings: []reviewer.RawFinding{{Title: "duplicate original", Body: "old", Priority: &priority}},
	})); err != nil {
		t.Fatalf("WriteReviewerOutput(original) error = %v", err)
	}
	if err := state.WriteReviewerOutput(runRoot, 1, 99, "cerberus-dedup#1", mustReviewerOutput(t, reviewer.RawReviewerOutput{
		Findings: []reviewer.RawFinding{{Title: "deduped final", Body: "new", Priority: &priority}},
	})); err != nil {
		t.Fatalf("WriteReviewerOutput(dedup) error = %v", err)
	}

	outputs := readReviewerOutputs(runRoot)
	if len(outputs) != 1 {
		t.Fatalf("outputs length = %d, want only post-review output", len(outputs))
	}
	if outputs[0].InstanceID != "cerberus-dedup#1" || len(outputs[0].Findings) != 1 || outputs[0].Findings[0].Title != "deduped final" {
		t.Fatalf("outputs = %#v, want dedup output only", outputs)
	}
}

func mustReviewerOutput(t *testing.T, output reviewer.RawReviewerOutput) []byte {
	t.Helper()
	data, err := json.Marshal(output)
	if err != nil {
		t.Fatalf("marshal reviewer output: %v", err)
	}
	return data
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

func TestHandleClaudeStopIgnoresEnvRunKeyGateForDifferentSession(t *testing.T) {
	env := &config.Env{
		Host:       "generic",
		StateRoot:  t.TempDir(),
		ProjectKey: "project",
		RunKey:     "run-a",
		SessionID:  "session-a",
	}
	staleGatePath := state.GateStatePath(state.RunDir(env.StateRoot, env.ProjectKey, "run-a"))
	if err := state.WriteGateState(staleGatePath, &state.GateState{Status: state.StatusPending, SessionID: "session-a"}); err != nil {
		t.Fatalf("seed stale pending gate: %v", err)
	}

	payload := []byte(`{"session_id":"session-b","transcript_path":"/tmp/session-b.jsonl"}`)
	_, err := handleClaudeStopWithWait(payload, env, 10*time.Millisecond, 30*time.Millisecond)
	if err != nil {
		t.Fatalf("HandleClaudeStop() error = %v, want session-b to ignore stale session-a gate", err)
	}

	if _, err := os.Stat(filepath.Join(env.StateRoot, env.ProjectKey, "session-b", "event-log.jsonl")); err != nil {
		t.Fatalf("session-b allowed event missing: %v", err)
	}
	staleEventsPath := filepath.Join(env.StateRoot, env.ProjectKey, "run-a", "event-log.jsonl")
	if _, err := os.Stat(staleEventsPath); !os.IsNotExist(err) {
		t.Fatalf("stale run was polled; stat %s err = %v", staleEventsPath, err)
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

func TestHandleCodexPromptSubmitIgnoresEnvRunKeyGateForDifferentSession(t *testing.T) {
	env := &config.Env{
		Host:       "generic",
		StateRoot:  t.TempDir(),
		ProjectKey: "project",
		RunKey:     "session-a",
	}
	gatePath := state.GateStatePath(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey))
	if err := state.WriteGateState(gatePath, &state.GateState{Status: state.StatusPending}); err != nil {
		t.Fatalf("seed active gate: %v", err)
	}

	payload := []byte(`{"session_id":"session-b","transcript_path":"/tmp/current.jsonl"}`)
	if err := HandleCodexPromptSubmit(payload, env); err != nil {
		t.Fatalf("HandleCodexPromptSubmit() error = %v", err)
	}

	data, err := os.ReadFile(filepath.Join(env.StateRoot, env.ProjectKey, "session-b", "session.json"))
	if err != nil {
		t.Fatalf("read current session.json: %v", err)
	}
	var got map[string]string
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal session.json: %v", err)
	}
	if got["run_key"] != "session-b" || got["session_id"] != "session-b" || got["transcript_path"] != "/tmp/current.jsonl" {
		t.Fatalf("session.json = %#v, want current session run key", got)
	}
	if _, err := os.Stat(filepath.Join(env.StateRoot, env.ProjectKey, "session-a", "session.json")); !os.IsNotExist(err) {
		t.Fatalf("stale env run was incorrectly refreshed; stat err = %v", err)
	}
}

func TestHandleCodexPromptSubmitIgnoresProjectPendingGateForDifferentSession(t *testing.T) {
	env := &config.Env{
		Host:       "generic",
		StateRoot:  t.TempDir(),
		ProjectKey: "project",
	}
	gatePath := state.GateStatePath(state.RunDir(env.StateRoot, env.ProjectKey, "session-a"))
	if err := state.WriteGateState(gatePath, &state.GateState{Status: state.StatusPending}); err != nil {
		t.Fatalf("seed active gate: %v", err)
	}

	payload := []byte(`{"session_id":"session-b","transcript_path":"/tmp/current.jsonl"}`)
	if err := HandleCodexPromptSubmit(payload, env); err != nil {
		t.Fatalf("HandleCodexPromptSubmit() error = %v", err)
	}

	data, err := os.ReadFile(filepath.Join(env.StateRoot, env.ProjectKey, "session-b", "session.json"))
	if err != nil {
		t.Fatalf("read current session.json: %v", err)
	}
	var got map[string]string
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal session.json: %v", err)
	}
	if got["run_key"] != "session-b" || got["session_id"] != "session-b" {
		t.Fatalf("session.json = %#v, want current session run key", got)
	}
	if _, err := os.Stat(filepath.Join(env.StateRoot, env.ProjectKey, "session-a", "session.json")); !os.IsNotExist(err) {
		t.Fatalf("project pending gate was incorrectly refreshed; stat err = %v", err)
	}
}

func TestHandleCodexPromptSubmitIgnoresProjectScopedCodexRunKeyForDifferentSession(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)

	env := &config.Env{
		Host:       "codex",
		ProjectKey: "project",
	}
	adapter, err := host.NewFromEnv(env)
	if err != nil {
		t.Fatalf("NewFromEnv() error = %v", err)
	}
	env.StateRoot, err = adapter.StateRoot(env)
	if err != nil {
		t.Fatalf("StateRoot() error = %v", err)
	}
	gatePath := state.GateStatePath(state.RunDir(env.StateRoot, env.ProjectKey, "active-run"))
	if err := state.WriteGateState(gatePath, &state.GateState{Status: state.StatusPending, SessionID: "other-session"}); err != nil {
		t.Fatalf("seed active gate: %v", err)
	}

	payload := []byte(`{"session_id":"codex-session-refresh","transcript_path":"/tmp/current.jsonl"}`)
	if err := HandleCodexPromptSubmit(payload, env); err != nil {
		t.Fatalf("HandleCodexPromptSubmit() error = %v", err)
	}

	data, err := os.ReadFile(filepath.Join(env.StateRoot, "codex-session-refresh", "session.json"))
	if err != nil {
		t.Fatalf("read current session.json: %v", err)
	}
	var got map[string]string
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal session.json: %v", err)
	}
	if got["run_key"] != "codex-session-refresh" || got["session_id"] != "codex-session-refresh" {
		t.Fatalf("session.json = %#v, want current session run key", got)
	}
	if _, err := os.Stat(filepath.Join(env.StateRoot, "active-run", "session.json")); !os.IsNotExist(err) {
		t.Fatalf("project-scoped active run was incorrectly refreshed; stat err = %v", err)
	}
}

func TestHandleCodexSessionStartUsesPayloadSessionWhenEnvRunHasNoGate(t *testing.T) {
	env := &config.Env{
		Host:       "generic",
		StateRoot:  t.TempDir(),
		ProjectKey: "project",
		RunKey:     "stale-session",
	}
	payload := []byte(`{"session_id":"current-session","transcript_path":"/tmp/current.jsonl"}`)

	if err := HandleCodexSessionStart(payload, env); err != nil {
		t.Fatalf("HandleCodexSessionStart() error = %v", err)
	}

	data, err := os.ReadFile(filepath.Join(env.StateRoot, env.ProjectKey, "current-session", "session.json"))
	if err != nil {
		t.Fatalf("read current session.json: %v", err)
	}
	var got map[string]string
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal session.json: %v", err)
	}
	if got["run_key"] != "current-session" || got["session_id"] != "current-session" {
		t.Fatalf("session.json = %#v, want payload session id to replace stale env run", got)
	}
}

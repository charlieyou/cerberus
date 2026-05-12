package hook

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/reviewer"
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
			if tc.name != "stop" {
				cache, err := state.ReadSessionCache(state.SessionCachePath(env.StateRoot, "codex-fixture-project"))
				if err != nil {
					t.Fatalf("ReadSessionCache() error = %v", err)
				}
				if cache.RunKey != "codex-fixture-session" || cache.TranscriptPath != "/tmp/cerberus/codex-fixture-session.jsonl" {
					t.Fatalf("active-session cache = %#v, want seeded run key and transcript path", cache)
				}
			}
		})
	}
}

func TestCodexSessionInitPreservesCachedRunKeyForSameSession(t *testing.T) {
	payload := []byte(`{"session_id":"codex-session","transcript_path":"/tmp/current.jsonl","project_key":"project"}`)
	env := &config.Env{Host: "codex", StateRoot: t.TempDir()}
	if err := state.WriteSessionCache(state.SessionCachePath(env.StateRoot, "project"), &state.SessionCache{
		Host:           "codex",
		ProjectKey:     "project",
		SessionID:      "codex-session",
		CodexSessionID: "codex-session",
		RunKey:         "existing-run",
		TranscriptPath: "/tmp/old.jsonl",
	}); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}

	if err := HandleCodexPromptSubmit(payload, env); err != nil {
		t.Fatalf("HandleCodexPromptSubmit() error = %v", err)
	}

	cache, err := state.ReadSessionCache(state.SessionCachePath(env.StateRoot, "project"))
	if err != nil {
		t.Fatalf("ReadSessionCache() error = %v", err)
	}
	if cache.RunKey != "existing-run" || cache.SessionID != "codex-session" || cache.TranscriptPath != "/tmp/current.jsonl" {
		t.Fatalf("cache = %#v, want preserved run key with refreshed transcript", cache)
	}
	if _, err := os.Stat(filepath.Join(env.StateRoot, "project", "existing-run", "session.json")); err != nil {
		t.Fatalf("preserved run session.json missing: %v", err)
	}
}

func TestCodexSessionInitWritesPluginRootCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	payload := []byte(`{"session_id":"codex-session","transcript_path":"/tmp/current.jsonl","project_key":"project"}`)
	env := &config.Env{Host: "codex", Root: "/plugin/root", StateRoot: t.TempDir()}

	if err := HandleCodexSessionStart(payload, env); err != nil {
		t.Fatalf("HandleCodexSessionStart() error = %v", err)
	}

	cachedRoot, err := config.ReadCodexPluginRootCache("codex-session")
	if err != nil {
		t.Fatalf("ReadCodexPluginRootCache() error = %v", err)
	}
	if cachedRoot != "/plugin/root" {
		t.Fatalf("cached plugin root = %q, want /plugin/root", cachedRoot)
	}
}

func TestCodexSessionInitIgnoresLeakedClaudeHost(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	payload := []byte(`{"session_id":"codex-session","transcript_path":"/tmp/current.jsonl","project_key":"project"}`)
	env := &config.Env{Host: "claude", Root: "/plugin/root"}

	if err := HandleCodexSessionStart(payload, env); err != nil {
		t.Fatalf("HandleCodexSessionStart() error = %v", err)
	}

	codexSessionPath := filepath.Join(home, ".codex", "projects", "project", "cerberus", "codex-session", "session.json")
	if _, err := os.Stat(codexSessionPath); err != nil {
		t.Fatalf("codex session state missing: %v", err)
	}
	claudeSessionPath := filepath.Join(home, ".claude", "projects", "project", "cerberus", "codex-session", "session.json")
	if _, err := os.Stat(claudeSessionPath); err == nil {
		t.Fatalf("codex hook wrote state through leaked claude host at %s", claudeSessionPath)
	} else if !os.IsNotExist(err) {
		t.Fatalf("stat leaked claude state path: %v", err)
	}
}

func TestCodexSessionInitPreservesCachedRunWhenSameSessionGateUnreadable(t *testing.T) {
	payload := []byte(`{"session_id":"codex-session","transcript_path":"/tmp/current.jsonl","project_key":"project"}`)
	env := &config.Env{Host: "codex", StateRoot: t.TempDir()}
	if err := state.WriteSessionCache(state.SessionCachePath(env.StateRoot, "project"), &state.SessionCache{
		Host:           "codex",
		ProjectKey:     "project",
		SessionID:      "codex-session",
		CodexSessionID: "codex-session",
		RunKey:         "existing-run",
		TranscriptPath: "/tmp/old.jsonl",
	}); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}
	gatePath := filepath.Join(env.StateRoot, "project", "existing-run", "gate-state.json")
	if err := os.MkdirAll(filepath.Dir(gatePath), 0o755); err != nil {
		t.Fatalf("create gate dir: %v", err)
	}
	if err := os.WriteFile(gatePath, []byte(`{"status":`), 0o644); err != nil {
		t.Fatalf("write malformed gate: %v", err)
	}

	if err := HandleCodexPromptSubmit(payload, env); err != nil {
		t.Fatalf("HandleCodexPromptSubmit() error = %v", err)
	}

	if _, err := os.Stat(filepath.Join(env.StateRoot, "project", "existing-run", "session.json")); err != nil {
		t.Fatalf("cached run session.json missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(env.StateRoot, "project", "codex-session", "session.json")); !os.IsNotExist(err) {
		t.Fatalf("payload session run was incorrectly used; stat err = %v", err)
	}
}

func TestCodexSessionInitIgnoresStaleCachedRunKeyForNewSession(t *testing.T) {
	env := &config.Env{Host: "codex", StateRoot: t.TempDir()}
	if err := state.WriteSessionCache(state.SessionCachePath(env.StateRoot, "project"), &state.SessionCache{
		Host:           "codex",
		ProjectKey:     "project",
		SessionID:      "old-session",
		CodexSessionID: "old-session",
		RunKey:         "old-run",
		TranscriptPath: "/tmp/old.jsonl",
	}); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}
	verdict := state.VerdictPass
	if err := state.WriteGateState(state.GateStatePath(state.RunDir(env.StateRoot, "project", "old-run")), &state.GateState{
		RunKey:         "old-run",
		Host:           "codex",
		ProjectKey:     "project",
		SessionID:      "old-session",
		TranscriptPath: "/tmp/old.jsonl",
		Status:         state.StatusResolved,
		Verdict:        &verdict,
	}); err != nil {
		t.Fatalf("seed resolved old gate: %v", err)
	}

	payload := []byte(`{"session_id":"new-session","transcript_path":"/tmp/new.jsonl","project_key":"project"}`)
	if err := HandleCodexSessionStart(payload, env); err != nil {
		t.Fatalf("HandleCodexSessionStart() error = %v", err)
	}

	cache, err := state.ReadSessionCache(state.SessionCachePath(env.StateRoot, "project"))
	if err != nil {
		t.Fatalf("ReadSessionCache() error = %v", err)
	}
	if cache.RunKey != "new-session" || cache.SessionID != "new-session" {
		t.Fatalf("cache = %#v, want new session to ignore stale cached run key", cache)
	}
	if _, err := os.Stat(filepath.Join(env.StateRoot, "project", "new-session", "session.json")); err != nil {
		t.Fatalf("new session.json missing: %v", err)
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
		_, err := handleCodexStopWithWait(payload, env, 10*time.Millisecond, time.Second)
		done <- err
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

func TestHandleCodexStopResponseEmitsClaudeStyleMessageOnce(t *testing.T) {
	payload := readCodexFixture(t, "hook-payload-stop.json")
	env := &config.Env{Host: "codex", StateRoot: t.TempDir()}
	runRoot := filepath.Join(env.StateRoot, "codex-fixture-project", "codex-fixture-session")
	gatePath := state.GateStatePath(runRoot)
	severity := "blocking"
	priority := 1
	filePath := "internal/service.go"
	line := 12
	output, err := json.Marshal(reviewer.RawReviewerOutput{
		Verdict: "FAIL",
		Summary: "Reviewer found a blocking issue.",
		Findings: []reviewer.RawFinding{{
			Title:     "Missing validation",
			Body:      "The handler trusts user input.",
			Severity:  &severity,
			Priority:  &priority,
			FilePath:  &filePath,
			LineStart: &line,
			LineEnd:   &line,
		}},
	})
	if err != nil {
		t.Fatalf("marshal reviewer output: %v", err)
	}
	if err := state.WriteReviewerOutput(runRoot, 1, 1, "codex#1", output); err != nil {
		t.Fatalf("WriteReviewerOutput() error = %v", err)
	}
	verdict := state.VerdictFail
	if err := state.WriteGateState(gatePath, &state.GateState{Status: state.StatusResolved, Verdict: &verdict}); err != nil {
		t.Fatalf("seed resolved gate: %v", err)
	}

	response, err := HandleCodexStopResponse(payload, env)
	if err != nil {
		t.Fatalf("HandleCodexStopResponse() error = %v", err)
	}
	var body map[string]string
	if err := json.Unmarshal([]byte(response), &body); err != nil {
		t.Fatalf("response is not JSON: %v\n%s", err, response)
	}
	if body["decision"] != "block" {
		t.Fatalf("decision = %q, want block", body["decision"])
	}
	for _, want := range []string{"## Revision Required", "Missing validation", "internal/service.go:12", "You MUST use subagents", "You MUST fix"} {
		if !strings.Contains(body["reason"], want) {
			t.Fatalf("reason missing %q:\n%s", want, body["reason"])
		}
	}

	second, err := HandleCodexStopResponse(payload, env)
	if err != nil {
		t.Fatalf("second HandleCodexStopResponse() error = %v", err)
	}
	if second != "" {
		t.Fatalf("second response = %q, want empty after marker", second)
	}
}

func TestStopHookResponseClaimsMarkerAtomically(t *testing.T) {
	runRoot := t.TempDir()
	verdict := state.VerdictPass
	result := &PollResult{
		RunRoot: runRoot,
		Gate:    &state.GateState{Status: state.StatusResolved, Verdict: &verdict},
	}

	const calls = 16
	responses := make(chan string, calls)
	errs := make(chan error, calls)
	var wg sync.WaitGroup
	for i := 0; i < calls; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			response, err := stopHookResponse(result)
			if err != nil {
				errs <- err
				return
			}
			responses <- response
		}()
	}
	wg.Wait()
	close(responses)
	close(errs)
	for err := range errs {
		t.Fatalf("stopHookResponse() error = %v", err)
	}
	emitted := 0
	for response := range responses {
		if response != "" {
			emitted++
		}
	}
	if emitted != 1 {
		t.Fatalf("emitted responses = %d, want 1", emitted)
	}
}

func TestHandleCodexStopReturnsErrorAfterMaxWait(t *testing.T) {
	payload := readCodexFixture(t, "hook-payload-stop.json")
	env := &config.Env{Host: "codex", StateRoot: t.TempDir()}
	gatePath := filepath.Join(env.StateRoot, "codex-fixture-project", "codex-fixture-session", "gate-state.json")
	if err := state.WriteGateState(gatePath, &state.GateState{Status: state.StatusPending}); err != nil {
		t.Fatalf("seed pending gate: %v", err)
	}

	_, err := handleCodexStopWithWait(payload, env, 10*time.Millisecond, 30*time.Millisecond)
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

func TestHandleCodexStopIgnoresStaleCachedRunForDifferentSession(t *testing.T) {
	env := &config.Env{Host: "codex", StateRoot: t.TempDir()}
	if err := state.WriteSessionCache(state.SessionCachePath(env.StateRoot, "project"), &state.SessionCache{
		Host:           "codex",
		ProjectKey:     "project",
		SessionID:      "session-a",
		CodexSessionID: "session-a",
		RunKey:         "run-a",
		TranscriptPath: "/tmp/session-a.jsonl",
	}); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}
	staleGatePath := filepath.Join(env.StateRoot, "project", "run-a", "gate-state.json")
	if err := state.WriteGateState(staleGatePath, &state.GateState{Status: state.StatusPending}); err != nil {
		t.Fatalf("seed stale pending gate: %v", err)
	}

	payload := []byte(`{"session_id":"session-b","transcript_path":"/tmp/session-b.jsonl","project_key":"project"}`)
	_, err := handleCodexStopWithWait(payload, env, 10*time.Millisecond, 30*time.Millisecond)
	if err != nil {
		t.Fatalf("HandleCodexStop() error = %v, want session-b to ignore stale session-a gate", err)
	}

	if _, err := os.Stat(filepath.Join(env.StateRoot, "project", "session-b", "event-log.jsonl")); err != nil {
		t.Fatalf("session-b allowed event missing: %v", err)
	}
	staleEventsPath := filepath.Join(env.StateRoot, "project", "run-a", "event-log.jsonl")
	if _, err := os.Stat(staleEventsPath); !os.IsNotExist(err) {
		t.Fatalf("stale run was polled; stat %s err = %v", staleEventsPath, err)
	}
}

func TestHandleCodexStopIgnoresPoisonedCachePointingAtDifferentSessionGate(t *testing.T) {
	env := &config.Env{Host: "codex", StateRoot: t.TempDir()}
	if err := state.WriteSessionCache(state.SessionCachePath(env.StateRoot, "project"), &state.SessionCache{
		Host:           "codex",
		ProjectKey:     "project",
		SessionID:      "session-b",
		CodexSessionID: "session-b",
		RunKey:         "run-a",
		TranscriptPath: "/tmp/session-b.jsonl",
	}); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}
	staleGatePath := filepath.Join(env.StateRoot, "project", "run-a", "gate-state.json")
	if err := state.WriteGateState(staleGatePath, &state.GateState{Status: state.StatusPending, SessionID: "session-a"}); err != nil {
		t.Fatalf("seed stale pending gate: %v", err)
	}

	payload := []byte(`{"session_id":"session-b","transcript_path":"/tmp/session-b.jsonl","project_key":"project"}`)
	_, err := handleCodexStopWithWait(payload, env, 10*time.Millisecond, 30*time.Millisecond)
	if err != nil {
		t.Fatalf("HandleCodexStop() error = %v, want session-b to ignore stale session-a gate", err)
	}

	staleEventsPath := filepath.Join(env.StateRoot, "project", "run-a", "event-log.jsonl")
	if _, err := os.Stat(staleEventsPath); !os.IsNotExist(err) {
		t.Fatalf("stale run was polled; stat %s err = %v", staleEventsPath, err)
	}
}

func TestHandleCodexStopWaitsOnCachedRunWhenSameSessionGateUnreadable(t *testing.T) {
	env := &config.Env{Host: "codex", StateRoot: t.TempDir()}
	if err := state.WriteSessionCache(state.SessionCachePath(env.StateRoot, "project"), &state.SessionCache{
		Host:           "codex",
		ProjectKey:     "project",
		SessionID:      "session-b",
		CodexSessionID: "session-b",
		RunKey:         "run-b",
		TranscriptPath: "/tmp/session-b.jsonl",
	}); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}
	gatePath := filepath.Join(env.StateRoot, "project", "run-b", "gate-state.json")
	if err := os.MkdirAll(filepath.Dir(gatePath), 0o755); err != nil {
		t.Fatalf("create gate dir: %v", err)
	}
	if err := os.WriteFile(gatePath, []byte(`{"status":`), 0o644); err != nil {
		t.Fatalf("write malformed gate: %v", err)
	}

	payload := []byte(`{"session_id":"session-b","transcript_path":"/tmp/session-b.jsonl","project_key":"project"}`)
	done := make(chan error, 1)
	go func() {
		_, err := handleCodexStopWithWait(payload, env, 10*time.Millisecond, time.Second)
		done <- err
	}()

	select {
	case err := <-done:
		t.Fatalf("HandleCodexStop() returned before same-session gate became readable: %v", err)
	case <-time.After(30 * time.Millisecond):
	}

	verdict := state.VerdictPass
	if err := state.WriteGateState(gatePath, &state.GateState{Status: state.StatusResolved, SessionID: "session-b", Verdict: &verdict}); err != nil {
		t.Fatalf("write resolved gate: %v", err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("HandleCodexStop() error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("HandleCodexStop() did not return after same-session gate resolved")
	}

	if _, err := os.Stat(filepath.Join(env.StateRoot, "project", "session-b", "event-log.jsonl")); !os.IsNotExist(err) {
		t.Fatalf("payload session run was incorrectly polled; stat err = %v", err)
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

	_, err := handleCodexStopWithWait(payload, env, 10*time.Millisecond, 30*time.Millisecond)
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

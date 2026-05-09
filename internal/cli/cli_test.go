package cli

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/state"
)

func TestRunCheck(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run([]string{"check"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("run(check) exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if got, want := stdout.String(), "no active review\n"; got != want {
		t.Fatalf("run(check) stdout = %q, want %q", got, want)
	}
	if stderr.Len() != 0 {
		t.Fatalf("run(check) stderr = %q, want empty", stderr.String())
	}
}

func TestRunUnknownSubcommand(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run([]string{"bogus"}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("run(unknown) exit code = 0, want non-zero")
	}
	if stdout.Len() != 0 {
		t.Fatalf("run(unknown) stdout = %q, want empty", stdout.String())
	}
	if got := stderr.String(); !strings.Contains(got, `unknown subcommand "bogus"`) || !strings.Contains(got, "usage: cerberus") {
		t.Fatalf("run(unknown) stderr = %q, want unknown-subcommand error and usage", got)
	}
}

func TestRunMissingSubcommand(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run(nil, &stdout, &stderr)

	if code == 0 {
		t.Fatal("run(no args) exit code = 0, want non-zero")
	}
	if stdout.Len() != 0 {
		t.Fatalf("run(no args) stdout = %q, want empty", stdout.String())
	}
	if got := stderr.String(); !strings.Contains(got, "usage: cerberus") {
		t.Fatalf("run(no args) stderr = %q, want usage", got)
	}
}

func TestActiveRunRootFallsBackToSessionCache(t *testing.T) {
	stateRoot := t.TempDir()
	projectKey := "project-key"
	cache := &state.SessionCache{
		Host:           "codex",
		ProjectKey:     projectKey,
		SessionID:      "codex-session",
		CodexSessionID: "codex-session",
		RunKey:         "active-run",
		TranscriptPath: "/tmp/codex-session.jsonl",
		LastSeen:       time.Date(2026, 5, 9, 12, 0, 0, 0, time.UTC),
	}
	if err := state.WriteSessionCache(state.SessionCachePath(stateRoot, projectKey), cache); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}
	t.Setenv("CERBERUS_HOST", "codex")
	t.Setenv("CERBERUS_STATE_ROOT", stateRoot)
	t.Setenv("CERBERUS_PROJECT_KEY", projectKey)
	t.Setenv("CERBERUS_RUN_KEY", "")
	t.Setenv("CERBERUS_SESSION_ID", "")

	got, ok, err := activeRunRoot()
	if err != nil {
		t.Fatalf("activeRunRoot() error = %v", err)
	}
	if !ok {
		t.Fatal("activeRunRoot() ok = false, want true")
	}
	want := filepath.Join(stateRoot, projectKey, "active-run")
	if got != want {
		t.Fatalf("activeRunRoot() = %q, want %q", got, want)
	}
}

func TestStatusAcceptsSessionKey(t *testing.T) {
	stateRoot := t.TempDir()
	projectKey := "project-key"
	runKey := "review-run"
	verdict := state.VerdictPass
	writeTestGateState(t, stateRoot, projectKey, runKey, state.StatusResolved, &verdict)
	t.Setenv("CERBERUS_HOST", "generic")
	t.Setenv("CERBERUS_STATE_ROOT", stateRoot)
	t.Setenv("CERBERUS_PROJECT_KEY", projectKey)
	t.Setenv("CERBERUS_RUN_KEY", "")

	var stdout, stderr bytes.Buffer
	code := run([]string{"status", "--json", "--session-key", runKey}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("status exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if got := stdout.String(); !strings.Contains(got, `"run_key": "`+runKey+`"`) || !strings.Contains(got, `"status": "resolved"`) {
		t.Fatalf("status stdout = %q, want resolved run %q", got, runKey)
	}
}

func TestWaitAcceptsLegacyPollingFlagsAndSessionKey(t *testing.T) {
	stateRoot := t.TempDir()
	projectKey := "project-key"
	runKey := "review-run"
	verdict := state.VerdictPass
	writeTestGateState(t, stateRoot, projectKey, runKey, state.StatusResolved, &verdict)
	t.Setenv("CERBERUS_HOST", "generic")
	t.Setenv("CERBERUS_STATE_ROOT", stateRoot)
	t.Setenv("CERBERUS_PROJECT_KEY", projectKey)
	t.Setenv("CERBERUS_RUN_KEY", "")

	var stdout, stderr bytes.Buffer
	code := run([]string{"wait", "--json", "--finalize", "--timeout", "5", "--poll-interval", "1", "--session-key", runKey}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("wait exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if got := stdout.String(); !strings.Contains(got, `"run_key": "`+runKey+`"`) || !strings.Contains(got, `"status": "resolved"`) {
		t.Fatalf("wait stdout = %q, want resolved run %q", got, runKey)
	}
}

func TestStatusSessionIDWinsOverSessionKey(t *testing.T) {
	stateRoot := t.TempDir()
	projectKey := "project-key"
	realRun := "session-run"
	decoyRun := "decoy-run"
	verdict := state.VerdictPass
	writeTestGateState(t, stateRoot, projectKey, realRun, state.StatusResolved, &verdict)
	writeTestGateState(t, stateRoot, projectKey, decoyRun, state.StatusPending, nil)
	t.Setenv("CERBERUS_HOST", "generic")
	t.Setenv("CERBERUS_STATE_ROOT", stateRoot)
	t.Setenv("CERBERUS_PROJECT_KEY", projectKey)
	t.Setenv("CERBERUS_RUN_KEY", "")

	var stdout, stderr bytes.Buffer
	code := run([]string{"status", "--json", "--session-id", realRun, "--session-key", decoyRun}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("status exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if got := stdout.String(); !strings.Contains(got, `"run_key": "`+realRun+`"`) || strings.Contains(got, `"run_key": "`+decoyRun+`"`) {
		t.Fatalf("status stdout = %q, want session-id run %q", got, realRun)
	}
}

func TestSpawnCodeReviewMaxRoundsFlagParsing(t *testing.T) {
	var stderr bytes.Buffer

	opts, err := parseSpawnCodeReviewFlags(nil, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags(default) error = %v", err)
	}
	if opts.maxRounds != 3 {
		t.Fatalf("default maxRounds = %d, want 3", opts.maxRounds)
	}

	opts, err = parseSpawnCodeReviewFlags([]string{"--max-rounds", "5"}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags(override) error = %v", err)
	}
	if opts.maxRounds != 5 {
		t.Fatalf("override maxRounds = %d, want 5", opts.maxRounds)
	}
}

func writeTestGateState(t *testing.T, stateRoot, projectKey, runKey, status string, verdict *string) {
	t.Helper()
	runRoot := state.RunDir(stateRoot, projectKey, runKey)
	if err := state.WriteGateState(state.GateStatePath(runRoot), &state.GateState{
		RunKey:     runKey,
		Host:       "generic",
		ProjectKey: projectKey,
		SessionID:  runKey,
		Status:     status,
		Verdict:    verdict,
		StartedAt:  time.Now().UTC(),
	}); err != nil {
		t.Fatalf("WriteGateState() error = %v", err)
	}
}

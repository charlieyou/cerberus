package integration_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/state"
)

func TestCodexSessionInitSeedsStatusResolutionFromCache(t *testing.T) {
	repoRoot := filepath.Join("..", "..")
	binary := filepath.Join(t.TempDir(), "cerberus")

	build := exec.Command("go", "build", "-o", binary, "./cmd/cerberus")
	build.Dir = repoRoot
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build ./cmd/cerberus failed: %v\n%s", err, output)
	}

	home := t.TempDir()
	projectKey := "codex-fixture-project"
	runKey := "codex-fixture-session"
	stateRoot := filepath.Join(home, ".codex", "projects", projectKey, "cerberus")

	for _, tc := range []struct {
		subcommand string
		fixture    string
	}{
		{subcommand: "codex-session-start", fixture: "hook-payload-session-start.json"},
		{subcommand: "codex-prompt-submit", fixture: "hook-payload-prompt-submit.json"},
	} {
		payload := readIntegrationCodexFixture(t, tc.fixture)
		cmd := exec.Command(binary, "hook", tc.subcommand)
		cmd.Stdin = strings.NewReader(string(payload))
		cmd.Env = append(os.Environ(),
			"CERBERUS_HOST=codex",
			"HOME="+home,
			"USERPROFILE="+home,
		)
		output, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("cerberus hook %s failed: %v\n%s", tc.subcommand, err, output)
		}
	}

	cache, err := state.ReadSessionCache(state.SessionCachePath(stateRoot, projectKey))
	if err != nil {
		t.Fatalf("ReadSessionCache() error = %v", err)
	}
	if cache.RunKey != runKey || cache.SessionID != runKey || cache.TranscriptPath != "/tmp/cerberus/codex-fixture-session.jsonl" {
		t.Fatalf("session cache = %#v, want fixture run/session/transcript", cache)
	}

	runRoot := state.RunDir(stateRoot, projectKey, runKey)
	if err := state.WriteGateState(state.GateStatePath(runRoot), &state.GateState{
		RunKey:           runKey,
		Host:             "codex",
		ProjectKey:       projectKey,
		SessionID:        runKey,
		TranscriptPath:   cache.TranscriptPath,
		Status:           state.StatusPending,
		CurrentIteration: 1,
		MaxRounds:        3,
		Mode:             "smart",
		StartedAt:        time.Now().UTC(),
	}); err != nil {
		t.Fatalf("seed gate state: %v", err)
	}

	status := exec.Command(binary, "status", "--json")
	status.Env = append(os.Environ(),
		"CERBERUS_HOST=codex",
		"CERBERUS_PROJECT_KEY="+projectKey,
		"HOME="+home,
		"USERPROFILE="+home,
	)
	output, err := status.CombinedOutput()
	if err != nil {
		t.Fatalf("cerberus status --json failed: %v\n%s", err, output)
	}

	var got state.GateState
	if err := json.Unmarshal(output, &got); err != nil {
		t.Fatalf("unmarshal status JSON: %v\n%s", err, output)
	}
	if got.RunKey != runKey || got.SessionID != runKey || got.TranscriptPath != cache.TranscriptPath {
		t.Fatalf("status gate = %#v, want identity resolved from session cache", got)
	}
}

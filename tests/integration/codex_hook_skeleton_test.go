package integration_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charlieyou/cerberus/internal/telemetry"
)

func TestCodexHookSkeletonSubcommandsReadStdinPayloads(t *testing.T) {
	repoRoot := filepath.Join("..", "..")
	binary := filepath.Join(t.TempDir(), "cerberus")

	build := exec.Command("go", "build", "-o", binary, "./cmd/cerberus")
	build.Dir = repoRoot
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build ./cmd/cerberus failed: %v\n%s", err, output)
	}

	stateRoot := t.TempDir()
	for _, tc := range []struct {
		subcommand string
		fixture    string
	}{
		{subcommand: "codex-session-start", fixture: "hook-payload-session-start.json"},
		{subcommand: "codex-prompt-submit", fixture: "hook-payload-prompt-submit.json"},
		{subcommand: "codex-stop", fixture: "hook-payload-stop.json"},
	} {
		t.Run(tc.subcommand, func(t *testing.T) {
			payload := readIntegrationCodexFixture(t, tc.fixture)
			cmd := exec.Command(binary, "hook", tc.subcommand)
			cmd.Stdin = strings.NewReader(string(payload))
			cmd.Env = append(os.Environ(),
				"CERBERUS_HOST=codex",
				"CERBERUS_STATE_ROOT="+stateRoot,
			)
			output, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("cerberus hook %s failed: %v\n%s", tc.subcommand, err, output)
			}

			event := readIntegrationSingleEvent(t, filepath.Join(stateRoot, "codex-fixture-project", "codex-fixture-session", "event-log.jsonl"))
			if event["event"] != telemetry.EventHookAllowed {
				t.Fatalf("event = %v, want %s", event["event"], telemetry.EventHookAllowed)
			}
			if tc.subcommand != "codex-stop" && event["project_key"] != "codex-fixture-project" {
				t.Fatalf("project_key = %v, want codex-fixture-project", event["project_key"])
			}
			if err := os.Remove(filepath.Join(stateRoot, "codex-fixture-project", "codex-fixture-session", "event-log.jsonl")); err != nil {
				t.Fatalf("remove event log: %v", err)
			}
		})
	}
}

func readIntegrationCodexFixture(t *testing.T, name string) []byte {
	t.Helper()

	data, err := os.ReadFile(filepath.Join("..", "fixtures", "codex", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return data
}

func readIntegrationSingleEvent(t *testing.T, path string) map[string]any {
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

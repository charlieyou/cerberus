package hook

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charlieyou/cerberus/internal/config"
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
			if event["session_id"] != "codex-fixture-session" {
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

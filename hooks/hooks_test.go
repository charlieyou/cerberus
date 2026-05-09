package hooks_test

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestClaudeStopHookInvokesGoGatePolling(t *testing.T) {
	data, err := os.ReadFile("hooks.json")
	if err != nil {
		t.Fatalf("read hooks.json: %v", err)
	}

	var manifest struct {
		Hooks map[string][]struct {
			Hooks []struct {
				Command string `json:"command"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("parse hooks.json: %v", err)
	}

	var commands []string
	for _, entry := range manifest.Hooks["Stop"] {
		for _, hook := range entry.Hooks {
			commands = append(commands, hook.Command)
		}
	}
	if len(commands) != 1 {
		t.Fatalf("Stop hook commands = %v, want exactly one", commands)
	}
	command := commands[0]
	if !strings.Contains(command, `exec "$bin" hook claude-stop`) {
		t.Fatalf("Stop hook command = %q, want Go claude-stop hook", command)
	}
	if !strings.Contains(command, `make -q -C "$root" build`) {
		t.Fatalf("Stop hook command = %q, want lazy build check", command)
	}
	if strings.Contains(command, "review-gate check") {
		t.Fatalf("Stop hook command = %q, must not bypass Go gate polling", command)
	}
}

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

func TestCodexHooksInvokeGoHookSubcommands(t *testing.T) {
	data, err := os.ReadFile("codex-hooks.json")
	if err != nil {
		t.Fatalf("read codex-hooks.json: %v", err)
	}

	var manifest struct {
		Hooks map[string][]struct {
			Hooks []struct {
				Command string `json:"command"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("parse codex-hooks.json: %v", err)
	}

	for event, subcommand := range map[string]string{
		"SessionStart":     "codex-session-start",
		"UserPromptSubmit": "codex-prompt-submit",
		"Stop":             "codex-stop",
	} {
		commands := hookCommands(manifest.Hooks[event])
		if len(commands) != 1 {
			t.Fatalf("%s hook commands = %v, want exactly one", event, commands)
		}
		command := commands[0]
		if !strings.Contains(command, `exec "$bin" hook `+subcommand) {
			t.Fatalf("%s hook command = %q, want Go %s hook", event, command, subcommand)
		}
		if !strings.Contains(command, `make -q -C "$root" build`) {
			t.Fatalf("%s hook command = %q, want lazy build check", event, command)
		}
		if strings.Contains(command, "/bin/bash") || strings.Contains(command, "codex-session-init") || strings.Contains(command, "codex-stop-hook") {
			t.Fatalf("%s hook command = %q, must not call legacy Codex scripts", event, command)
		}
	}
}

func hookCommands(entries []struct {
	Hooks []struct {
		Command string `json:"command"`
	} `json:"hooks"`
}) []string {
	var commands []string
	for _, entry := range entries {
		for _, hook := range entry.Hooks {
			commands = append(commands, hook.Command)
		}
	}
	return commands
}

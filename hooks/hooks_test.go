package hooks_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
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
	assertNoLegacyHookTerms(t, "hooks.json", string(data))

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
	if strings.Contains(command, "review"+"-gate check") {
		t.Fatalf("Stop hook command = %q, must not bypass Go gate polling", command)
	}
}

func TestCodexHooksInvokeGoHookSubcommands(t *testing.T) {
	assertCodexHookManifest(t, "codex-hooks.json")
}

func TestCodexHookTemplateRemoved(t *testing.T) {
	if _, err := os.Stat("../templates/codex-hooks.json"); err == nil {
		t.Fatal("legacy templates/codex-hooks.json exists, want removed")
	} else if !os.IsNotExist(err) {
		t.Fatalf("stat legacy templates/codex-hooks.json: %v", err)
	}
}

func TestCodexPluginExposesOnlySurvivingSkills(t *testing.T) {
	data, err := os.ReadFile("../.codex-plugin/plugin.json")
	if err != nil {
		t.Fatalf("read codex plugin manifest: %v", err)
	}
	var manifest struct {
		Skills string `json:"skills"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("parse codex plugin manifest: %v", err)
	}
	if manifest.Skills != "./skills/" {
		t.Fatalf("codex plugin skills path = %q, want ./skills/", manifest.Skills)
	}

	root := filepath.Clean(filepath.Join("..", manifest.Skills))
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read codex skills dir: %v", err)
	}
	var skills []string
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		if _, err := os.Stat(filepath.Join(root, entry.Name(), "SKILL.md")); err == nil {
			skills = append(skills, entry.Name())
		} else if !os.IsNotExist(err) {
			t.Fatalf("stat skill %s: %v", entry.Name(), err)
		}
	}
	want := []string{
		"architecture-review",
		"ask",
		"clear-gate",
		"create-plan",
		"create-spec",
		"create-tasks",
		"healthcheck",
		"review-code",
		"review-plan",
		"review-spec",
		"review-tasks",
		"status",
		"verify-epic",
	}
	if !reflect.DeepEqual(skills, want) {
		t.Fatalf("codex skills = %v, want %v", skills, want)
	}
}

func assertCodexHookManifest(t *testing.T, path string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var manifest struct {
		Hooks map[string][]struct {
			Hooks []struct {
				Command string `json:"command"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	assertNoLegacyHookTerms(t, path, string(data))

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
		if strings.Contains(command, "/bin/bash") || strings.Contains(command, "codex"+"-session-init") || strings.Contains(command, "codex"+"-stop-hook") {
			t.Fatalf("%s hook command = %q, must not call legacy Codex scripts", event, command)
		}
	}
}

func assertNoLegacyHookTerms(t *testing.T, path, text string) {
	t.Helper()
	for _, term := range []string{
		"task" + "-completed-hook",
		"teammate" + "-idle-hook",
		"run" + "-team",
	} {
		if strings.Contains(text, term) {
			t.Fatalf("%s contains legacy hook wiring term %q", path, term)
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

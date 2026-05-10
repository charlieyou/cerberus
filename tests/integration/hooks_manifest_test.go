package integration_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"testing"
)

type hookManifest struct {
	Hooks map[string][]hookEntry `json:"hooks"`
}

type hookEntry struct {
	Hooks []hookCommand `json:"hooks"`
}

type hookCommand struct {
	Type    string `json:"type"`
	Command string `json:"command"`
	Timeout *int   `json:"timeout,omitempty"`
}

func TestHookManifestsUseCanonicalLazyBuildBootstrap(t *testing.T) {
	repoRoot := hooksManifestRepoRoot(t)
	canonicalResolver := compactCanonicalHookResolver(t, filepath.Join(repoRoot, "prompts", "host-neutral-bootstrap.md"))

	tests := []struct {
		name     string
		path     string
		rootLine string
		events   map[string]string
	}{
		{
			name:     "claude",
			path:     filepath.Join(repoRoot, "hooks", "hooks.json"),
			rootLine: `root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"`,
			events: map[string]string{
				"SessionStart": "claude-session-start",
				"Stop":         "claude-stop",
			},
		},
		{
			name:     "codex",
			path:     filepath.Join(repoRoot, "hooks", "codex-hooks.json"),
			rootLine: `root="${CERBERUS_ROOT:-${PLUGIN_ROOT:-}}"`,
			events: map[string]string{
				"SessionStart":     "codex-session-start",
				"UserPromptSubmit": "codex-prompt-submit",
				"Stop":             "codex-stop",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			data, err := os.ReadFile(tt.path)
			if err != nil {
				t.Fatalf("ReadFile(%s) error = %v", tt.path, err)
			}
			assertNoRemovedHookEvents(t, tt.path, string(data))

			var manifest hookManifest
			if err := json.Unmarshal(data, &manifest); err != nil {
				t.Fatalf("json.Unmarshal(%s) error = %v", tt.path, err)
			}
			assertEventSet(t, tt.path, manifest.Hooks, keys(tt.events))

			resolver := strings.Replace(canonicalResolver, `root="${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}"`, tt.rootLine, 1)
			for event, hookName := range tt.events {
				command := onlyHookCommand(t, tt.path, event, manifest.Hooks[event])
				if command.Type != "command" {
					t.Fatalf("%s %s type = %q, want command", tt.path, event, command.Type)
				}

				wantCommand := "sh -c '" + resolver + `; exec "$bin" hook ` + hookName + "'"
				if command.Command != wantCommand {
					t.Fatalf("%s %s command drifted from canonical resolver\nwant: %s\n got: %s", tt.path, event, wantCommand, command.Command)
				}
				if strings.Contains(command.Command, `"$@"`) {
					t.Fatalf("%s %s command must not forward positional arguments: %s", tt.path, event, command.Command)
				}
				if strings.Contains(command.Command, `exec "$bin" "$@"`) {
					t.Fatalf("%s %s command must use hook exec form, not skill exec form", tt.path, event)
				}
				assertStopTimeout(t, tt.path, event, command.Timeout)
			}
		})
	}
}

func compactCanonicalHookResolver(t *testing.T, path string) string {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	body, err := extractHookManifestResolverBody(string(data))
	if err != nil {
		t.Fatalf("extractHookManifestResolverBody(%s) error = %v", path, err)
	}

	var lines []string
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "# ---") {
			continue
		}
		lines = append(lines, line)
	}

	resolver := strings.Join(lines, "; ")
	return strings.ReplaceAll(resolver, "; then; ", "; then ")
}

func onlyHookCommand(t *testing.T, path, event string, entries []hookEntry) hookCommand {
	t.Helper()
	if len(entries) != 1 {
		t.Fatalf("%s %s entries = %d, want 1", path, event, len(entries))
	}
	if len(entries[0].Hooks) != 1 {
		t.Fatalf("%s %s hooks = %d, want 1", path, event, len(entries[0].Hooks))
	}
	return entries[0].Hooks[0]
}

func assertEventSet(t *testing.T, path string, got map[string][]hookEntry, want []string) {
	t.Helper()
	gotKeys := make([]string, 0, len(got))
	for event := range got {
		gotKeys = append(gotKeys, event)
	}
	sort.Strings(gotKeys)
	sort.Strings(want)
	if !reflect.DeepEqual(gotKeys, want) {
		t.Fatalf("%s events = %v, want %v", path, gotKeys, want)
	}
}

func keys(events map[string]string) []string {
	out := make([]string, 0, len(events))
	for event := range events {
		out = append(out, event)
	}
	sort.Strings(out)
	return out
}

func assertNoRemovedHookEvents(t *testing.T, path, text string) {
	t.Helper()
	for _, event := range []string{"TaskCompleted", "TeammateIdle"} {
		if strings.Contains(text, event) {
			t.Fatalf("%s must not contain removed hook event %s", path, event)
		}
	}
}

func assertStopTimeout(t *testing.T, path, event string, timeout *int) {
	t.Helper()
	if event != "Stop" {
		if timeout != nil {
			t.Fatalf("%s %s timeout = %d, want no timeout", path, event, *timeout)
		}
		return
	}
	if timeout == nil || *timeout != 2100 {
		if timeout == nil {
			t.Fatalf("%s Stop timeout missing, want 2100", path)
		}
		t.Fatalf("%s Stop timeout = %d, want 2100", path, *timeout)
	}
}

func extractHookManifestResolverBody(input string) (string, error) {
	const (
		startMarker = "# --- shared resolver (canonical body; identical across all callers) ---"
		endMarker   = "# --- shared resolver above; per-caller exec below (allowed to diverge) ---"
	)

	start := strings.Index(input, startMarker)
	if start < 0 {
		return "", errHookManifestMissingResolverStart
	}

	bodyStart := start + len(startMarker)
	end := strings.Index(input[bodyStart:], endMarker)
	if end < 0 {
		return "", errHookManifestMissingResolverEnd
	}

	body := input[start : bodyStart+end]
	if input[bodyStart:bodyStart+end] == "" {
		return "", errHookManifestEmptyResolverBody
	}
	return body, nil
}

type hookManifestResolverParseError string

func (e hookManifestResolverParseError) Error() string {
	return string(e)
}

const (
	errHookManifestMissingResolverStart hookManifestResolverParseError = "missing shared resolver start marker"
	errHookManifestMissingResolverEnd   hookManifestResolverParseError = "missing shared resolver end marker"
	errHookManifestEmptyResolverBody    hookManifestResolverParseError = "empty shared resolver body"
)

func hooksManifestRepoRoot(t *testing.T) string {
	t.Helper()

	_, path, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(path), "..", ".."))
}

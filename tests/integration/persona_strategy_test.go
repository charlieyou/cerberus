package integration_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPersonaStrategyPromptCapture(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	stateRoot := t.TempDir()
	recordDir := t.TempDir()
	fixtureDir := t.TempDir()
	xdgConfigHome := t.TempDir()
	writeIntegrationFile(t, xdgConfigHome, "cerberus/security-persona.md", "Persona Marker: defend the release gate.")
	writeIntegrationFile(t, xdgConfigHome, "cerberus/config.yaml", `version: 1
roster:
  persona-strategy:
    models:
      - provider: codex
        model: gpt-5.5
        effort: high
        strategy: verification-first
        persona: security-persona.md
`)

	cmd := exec.Command(binary, "spawn-code-review", "--mode", "persona-strategy", "persona strategy capture")
	cmd.Dir = repoRoot
	cmd.Env = append(os.Environ(),
		"CERBERUS_HOST=generic",
		"CERBERUS_ROOT="+repoRoot,
		"CERBERUS_STATE_ROOT="+stateRoot,
		"CERBERUS_PROJECT_KEY=persona-strategy",
		"CERBERUS_RUN_KEY=capture",
		"CERBERUS_FIXTURE_DIR="+fixtureDir,
		"CERBERUS_MOCK_RECORD_DIR="+recordDir,
		"PATH="+integrationMockPath(t, repoRoot)+string(os.PathListSeparator)+os.Getenv("PATH"),
		"XDG_CONFIG_HOME="+xdgConfigHome,
	)
	output, err := cmd.CombinedOutput()
	if err != nil && !strings.Contains(string(output), "no fixture for prompt+instance") {
		t.Fatalf("spawn-code-review failed before prompt capture: %v\n%s", err, output)
	}
	if err == nil {
		waitForResolvedGate(t, filepath.Join(stateRoot, "persona-strategy", "capture"))
	}

	waitForIntegrationFile(t, filepath.Join(recordDir, "codex.args"))
	args, err := os.ReadFile(filepath.Join(recordDir, "codex.args"))
	if err != nil {
		t.Fatalf("ReadFile(codex.args) error = %v", err)
	}
	for _, want := range []string{"Persona Marker: defend the release gate.", "Strategy: verification-first."} {
		if !strings.Contains(string(args), want) {
			t.Fatalf("codex args = %q, want %q", args, want)
		}
	}

	capture := waitForPromptCapture(t, fixtureDir)
	prompt, err := os.ReadFile(capture)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", capture, err)
	}
	if !strings.Contains(string(prompt), "persona strategy capture") {
		t.Fatalf("captured prompt = %q, want original review prompt", prompt)
	}
}

func waitForPromptCapture(t *testing.T, dir string) string {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		var found string
		err := filepath.WalkDir(dir, func(path string, entry os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if !entry.IsDir() && strings.HasSuffix(path, ".prompt.txt") {
				found = path
			}
			return nil
		})
		if err != nil {
			t.Fatalf("WalkDir(%s) error = %v", dir, err)
		}
		if found != "" {
			return found
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no missing-fixture prompt capture appeared in %s", dir)
	return ""
}

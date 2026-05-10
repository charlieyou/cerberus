package integration_test

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCodexDefaultRosterDegradesToCodexOnlyAndRuns(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	projectRoot := initIntegrationGitRepo(t)
	stateRoot := t.TempDir()
	reviewerBin := codexOnlyReviewerPath(t)

	cmd := exec.Command(binary, "spawn-code-review", "codex host default roster")
	cmd.Dir = projectRoot
	cmd.Env = append(os.Environ(),
		"CERBERUS_HOST=codex",
		"CERBERUS_ROOT="+repoRoot,
		"CERBERUS_STATE_ROOT="+stateRoot,
		"CERBERUS_PROJECT_KEY=codex-degrade",
		"CERBERUS_RUN_KEY=codex-only",
		"PATH="+reviewerBin+string(os.PathListSeparator)+"/usr/bin"+string(os.PathListSeparator)+"/bin",
	)

	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("spawn-code-review failed: %v\n%s", err, output)
	}
	out := string(output)
	assertIntegrationWarningCount(t, out, "claude", 1)
	assertIntegrationWarningCount(t, out, "gemini", 1)
	if !strings.Contains(out, "review spawned") {
		t.Fatalf("output = %q, want review spawned", out)
	}
	if _, err := os.Stat(filepath.Join(stateRoot, "codex-degrade", "codex-only", "gate-state.json")); err != nil {
		t.Fatalf("gate-state.json not created for degraded codex-only run: %v", err)
	}
	waitForIntegrationFile(t, filepath.Join(stateRoot, "codex-degrade", "codex-only", "iterations", "1", "round-1", "reviewers", "codex#1", "telemetry.json"))
}

func TestDefaultRosterDegradesMissingGeminiToTwoSlots(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	projectRoot := initIntegrationGitRepo(t)
	stateRoot := t.TempDir()
	reviewerBin := claudeCodexReviewerPath(t)

	cmd := exec.Command(binary, "spawn-code-review", "default panel without gemini")
	cmd.Dir = projectRoot
	cmd.Env = append(os.Environ(),
		"CERBERUS_HOST=generic",
		"CERBERUS_ROOT="+repoRoot,
		"CERBERUS_STATE_ROOT="+stateRoot,
		"CERBERUS_PROJECT_KEY=default-degrade",
		"CERBERUS_RUN_KEY=missing-gemini",
		"PATH="+reviewerBin+string(os.PathListSeparator)+"/usr/bin"+string(os.PathListSeparator)+"/bin",
	)

	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("spawn-code-review failed: %v\n%s", err, output)
	}
	out := string(output)
	assertIntegrationWarningCount(t, out, "gemini", 1)
	if strings.Contains(out, `warning: default panel CLI "claude"`) || strings.Contains(out, `warning: default panel CLI "codex"`) {
		t.Fatalf("output = %q, want only gemini degradation warning", out)
	}
	runRoot := filepath.Join(stateRoot, "default-degrade", "missing-gemini")
	waitForResolvedGate(t, runRoot)
	waitForIntegrationFile(t, filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "claude#1", "telemetry.json"))
	waitForIntegrationFile(t, filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "codex#1", "telemetry.json"))
	if _, err := os.Stat(filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "gemini#1", "telemetry.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("gemini telemetry stat err = %v, want not exist", err)
	}
}

func TestYAMLRosterNamedDefaultRejectsMissingGemini(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	projectRoot := initIntegrationGitRepo(t)
	stateRoot := t.TempDir()
	reviewerBin := claudeCodexReviewerPath(t)
	xdgConfigHome := t.TempDir()
	writeIntegrationFile(t, xdgConfigHome, "cerberus/rosters.yaml", `version: 1
rosters:
  default:
    reviewers:
      - provider: claude
        model: claude-opus-4-7
      - provider: codex
        model: gpt-5.5
      - provider: gemini
        model: gemini-3.1-pro
`)

	cmd := exec.Command(binary, "spawn-code-review", "yaml default requires gemini")
	cmd.Dir = projectRoot
	cmd.Env = append(os.Environ(),
		"CERBERUS_HOST=generic",
		"CERBERUS_ROOT="+repoRoot,
		"CERBERUS_STATE_ROOT="+stateRoot,
		"CERBERUS_PROJECT_KEY=default-degrade",
		"CERBERUS_RUN_KEY=yaml-default-missing-gemini",
		"PATH="+reviewerBin+string(os.PathListSeparator)+"/usr/bin"+string(os.PathListSeparator)+"/bin",
		"XDG_CONFIG_HOME="+xdgConfigHome,
	)

	output, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("spawn-code-review succeeded, want YAML default missing-CLI rejection\n%s", output)
	}
	out := string(output)
	if !strings.Contains(out, `roster "default" slot 3`) || !strings.Contains(out, `provider CLI "gemini" is not available on PATH`) {
		t.Fatalf("output = %q, want strict YAML default missing gemini error", out)
	}
}

func TestCodexDefaultRosterDegradationRefusesEmptyAndDebateOneReviewer(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)

	t.Run("empty roster", func(t *testing.T) {
		projectRoot := initIntegrationGitRepo(t)
		stateRoot := t.TempDir()
		emptyBin := filepath.Join(t.TempDir(), "bin")
		if err := os.MkdirAll(emptyBin, 0o755); err != nil {
			t.Fatalf("MkdirAll(empty bin) error = %v", err)
		}

		cmd := exec.Command(binary, "spawn-code-review", "codex host empty default roster")
		cmd.Dir = projectRoot
		cmd.Env = append(os.Environ(),
			"CERBERUS_HOST=codex",
			"CERBERUS_ROOT="+repoRoot,
			"CERBERUS_STATE_ROOT="+stateRoot,
			"CERBERUS_PROJECT_KEY=codex-degrade",
			"CERBERUS_RUN_KEY=empty-roster",
			"PATH="+emptyBin,
		)

		output, err := cmd.CombinedOutput()
		if err == nil {
			t.Fatalf("spawn-code-review succeeded, want empty roster refusal\n%s", output)
		}
		out := string(output)
		if !strings.Contains(out, "empty roster after degradation") {
			t.Fatalf("output = %q, want empty roster after degradation", out)
		}
		if _, statErr := os.Stat(filepath.Join(stateRoot, "codex-degrade", "empty-roster", "gate-state.json")); !errors.Is(statErr, os.ErrNotExist) {
			t.Fatalf("gate-state stat error = %v, want not exist", statErr)
		}
	})

	t.Run("debate one reviewer", func(t *testing.T) {
		projectRoot := initIntegrationGitRepo(t)
		stateRoot := t.TempDir()
		reviewerBin := codexOnlyReviewerPath(t)

		cmd := exec.Command(binary, "spawn-code-review", "--debate", "codex host debate")
		cmd.Dir = projectRoot
		cmd.Env = append(os.Environ(),
			"CERBERUS_HOST=codex",
			"CERBERUS_ROOT="+repoRoot,
			"CERBERUS_STATE_ROOT="+stateRoot,
			"CERBERUS_PROJECT_KEY=codex-degrade",
			"CERBERUS_RUN_KEY=debate-one",
			"PATH="+reviewerBin+string(os.PathListSeparator)+"/usr/bin"+string(os.PathListSeparator)+"/bin",
		)

		output, err := cmd.CombinedOutput()
		if err == nil {
			t.Fatalf("spawn-code-review --debate succeeded, want one-reviewer refusal\n%s", output)
		}
		out := string(output)
		assertIntegrationWarningCount(t, out, "claude", 1)
		assertIntegrationWarningCount(t, out, "gemini", 1)
		if !strings.Contains(out, "--debate requires at least 2 reviewers in the resolved roster (got 1)") {
			t.Fatalf("output = %q, want degraded one-reviewer debate refusal", out)
		}
	})
}

func codexOnlyReviewerPath(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "bin")
	script := `#!/bin/sh
while IFS= read -r _line; do
  :
done
printf '{"findings":[],"verdict":"PASS","summary":"mock codex pass","overall_confidence":0.9,"strategy":"mock","round":1,"peer_responses_seen":[]}\n'
`
	path := filepath.Join(bin, "codex")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatalf("MkdirAll(%s) error = %v", bin, err)
	}
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("WriteFile(codex) error = %v", err)
	}
	return bin
}

func claudeCodexReviewerPath(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "bin")
	script := `#!/bin/sh
while IFS= read -r _line; do
  :
done
printf '{"findings":[],"verdict":"PASS","summary":"mock pass","overall_confidence":0.9,"strategy":"mock","round":1,"peer_responses_seen":[]}\n'
`
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatalf("MkdirAll(%s) error = %v", bin, err)
	}
	for _, provider := range []string{"claude", "codex"} {
		path := filepath.Join(bin, provider)
		if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
			t.Fatalf("WriteFile(%s) error = %v", provider, err)
		}
	}
	return bin
}

func initIntegrationGitRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{
		{"init"},
		{"config", "user.email", "test@example.com"},
		{"config", "user.name", "Test User"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, output)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("initial\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(README.md) error = %v", err)
	}
	for _, args := range [][]string{
		{"add", "README.md"},
		{"commit", "-m", "initial"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, output)
		}
	}
	return dir
}

func assertIntegrationWarningCount(t *testing.T, output, provider string, want int) {
	t.Helper()
	needle := `warning: default panel CLI "` + provider + `" missing on PATH; skipping slot`
	if got := strings.Count(output, needle); got != want {
		t.Fatalf("warning count for %s = %d, want %d; output = %q", provider, got, want, output)
	}
}

func waitForIntegrationFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		} else {
			lastErr = err
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%s did not appear: %v", path, lastErr)
}

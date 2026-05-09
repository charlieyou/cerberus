package roster

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuiltInDefaultDegradesWhenClaudeMissingOnCodexHost(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	t.Setenv("CERBERUS_HOST", "codex")
	withFakeCLIsForProviders(t, dir, "codex", "gemini")

	var slots []RosterSlot
	stderr := captureStderr(t, func() {
		var err error
		slots, err = ResolveWithOptions(nil, ResolveOptions{})
		if err != nil {
			t.Fatalf("ResolveWithOptions() error = %v", err)
		}
	})

	assertInstanceIDs(t, slots, []string{"codex#1", "gemini#1"})
	assertWarningCount(t, stderr, "claude", 1)
	assertWarningCount(t, stderr, "gemini", 0)
}

func TestBuiltInDefaultDegradesToCodexOnlyOnCodexHost(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	t.Setenv("CERBERUS_HOST", "codex")
	withFakeCLIsForProviders(t, dir, "codex")

	var slots []RosterSlot
	stderr := captureStderr(t, func() {
		var err error
		slots, err = ResolveWithOptions(nil, ResolveOptions{})
		if err != nil {
			t.Fatalf("ResolveWithOptions() error = %v", err)
		}
	})

	assertInstanceIDs(t, slots, []string{"codex#1"})
	assertWarningCount(t, stderr, "claude", 1)
	assertWarningCount(t, stderr, "gemini", 1)
}

func TestBuiltInDefaultRefusesWhenAllReviewersMissingAfterDegradation(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	t.Setenv("CERBERUS_HOST", "codex")
	t.Setenv("PATH", filepath.Join(dir, "empty-bin"))

	var err error
	stderr := captureStderr(t, func() {
		_, err = ResolveWithOptions(nil, ResolveOptions{})
	})

	if err == nil {
		t.Fatal("ResolveWithOptions() error = nil, want empty degraded roster error")
	}
	if !strings.Contains(err.Error(), "empty roster after degradation") {
		t.Fatalf("error = %q, want empty roster after degradation", err.Error())
	}
	assertWarningCount(t, stderr, "claude", 1)
	assertWarningCount(t, stderr, "codex", 1)
	assertWarningCount(t, stderr, "gemini", 1)
}

func TestBuiltInDefaultDebateRefusesAfterDegradingToOneReviewer(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	t.Setenv("CERBERUS_HOST", "codex")
	withFakeCLIsForProviders(t, dir, "codex")

	var err error
	stderr := captureStderr(t, func() {
		_, err = ResolveWithOptions(nil, ResolveOptions{Debate: true})
	})

	if err == nil {
		t.Fatal("ResolveWithOptions() error = nil, want debate minimum error")
	}
	var preflight PreflightError
	if !errors.As(err, &preflight) {
		t.Fatalf("ResolveWithOptions() error type = %T, want PreflightError", err)
	}
	if preflight.TelemetryReason() != DebateMinimumReason {
		t.Fatalf("TelemetryReason() = %q, want %q", preflight.TelemetryReason(), DebateMinimumReason)
	}
	if !strings.Contains(err.Error(), "--debate requires at least 2 reviewers in the resolved roster (got 1)") {
		t.Fatalf("error = %q, want degraded one-reviewer debate refusal", err.Error())
	}
	assertWarningCount(t, stderr, "claude", 1)
	assertWarningCount(t, stderr, "gemini", 1)
}

func withFakeCLIsForProviders(t *testing.T, dir string, providers ...string) {
	t.Helper()
	bin := filepath.Join(dir, "bin")
	for _, name := range providers {
		writeFile(t, filepath.Join(bin, name), "#!/bin/sh\nexit 0\n")
		if err := os.Chmod(filepath.Join(bin, name), 0o755); err != nil {
			t.Fatalf("Chmod(%s) error = %v", name, err)
		}
	}
	t.Setenv("PATH", bin)
}

func assertWarningCount(t *testing.T, stderr, provider string, want int) {
	t.Helper()
	needle := `warning: default panel CLI "` + provider + `" missing on PATH; skipping slot`
	if got := strings.Count(stderr, needle); got != want {
		t.Fatalf("warning count for %s = %d, want %d; stderr = %q", provider, got, want, stderr)
	}
}

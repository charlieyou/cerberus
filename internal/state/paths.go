package state

import (
	"fmt"
	"os"
	"path/filepath"
)

const gateStateFilename = "gate-state.json"

const sessionCacheFilename = "active-session.json"

// RunDir returns the canonical <state_root>/<project>/<run> directory.
func RunDir(stateRoot, projectKey, run string) string {
	if filepath.Base(stateRoot) == "cerberus" && filepath.Base(filepath.Dir(stateRoot)) == projectKey {
		return filepath.Join(stateRoot, run)
	}
	return filepath.Join(stateRoot, projectKey, run)
}

// SessionCachePath returns the project-scoped active session cache path.
func SessionCachePath(stateRoot, projectKey string) string {
	if filepath.Base(stateRoot) == "cerberus" && filepath.Base(filepath.Dir(stateRoot)) == projectKey {
		return filepath.Join(stateRoot, sessionCacheFilename)
	}
	return filepath.Join(stateRoot, projectKey, sessionCacheFilename)
}

// GateStatePath returns the canonical gate-state.json path under runRoot.
func GateStatePath(runRoot string) string {
	return filepath.Join(runRoot, gateStateFilename)
}

// EnsureRunDir creates the canonical run directory.
func EnsureRunDir(runRoot string) error {
	if err := os.MkdirAll(runRoot, 0o755); err != nil {
		return fmt.Errorf("create run directory: %w", err)
	}
	return nil
}

// IterationDir returns the canonical iteration directory for a 1-based index.
func IterationDir(runRoot string, n int) string {
	return filepath.Join(runRoot, "iterations", fmt.Sprintf("%d", n))
}

// RoundDir returns the canonical round directory for 1-based indexes.
func RoundDir(runRoot string, iteration, round int) string {
	return filepath.Join(IterationDir(runRoot, iteration), fmt.Sprintf("round-%d", round))
}

// ReviewerDir returns the canonical reviewer output directory.
func ReviewerDir(runRoot string, iteration, round int, instanceID string) string {
	return filepath.Join(RoundDir(runRoot, iteration, round), "reviewers", instanceID)
}

// WriteReviewerOutput writes canonical reviewer JSON output.
func WriteReviewerOutput(runRoot string, iteration, round int, instanceID string, jsonBytes []byte) error {
	reviewerDir := ReviewerDir(runRoot, iteration, round, instanceID)
	if err := os.MkdirAll(reviewerDir, 0o755); err != nil {
		return fmt.Errorf("create reviewer directory: %w", err)
	}
	if err := os.WriteFile(filepath.Join(reviewerDir, "output.json"), jsonBytes, 0o644); err != nil {
		return fmt.Errorf("write reviewer output: %w", err)
	}
	return nil
}

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunRejectsLegacyDebateRuntime(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "bin/review-gate-debate.sh", "#!/bin/sh\n")

	err := run(root)
	if err == nil || !strings.Contains(err.Error(), "legacy shell debate runtime") {
		t.Fatalf("run() error = %v, want legacy debate runtime failure", err)
	}
}

func TestRunRejectsAggregationImportOutsideOrchestratorAndTests(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "internal/cli/bad.go", `package cli

import "github.com/charlieyou/cerberus/internal/aggregate"

var _ = aggregate.ModeMajority
`)

	err := run(root)
	if err == nil || !strings.Contains(err.Error(), "may only be imported by internal/orchestrator or tests") {
		t.Fatalf("run() error = %v, want import boundary failure", err)
	}
}

func TestRunRejectsStateImportOutsideApprovedOwnersAndTests(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "internal/cli/new_bypass.go", `package cli

import "github.com/charlieyou/cerberus/internal/state"

var _ = state.StatusPending
`)

	err := run(root)
	if err == nil || !strings.Contains(err.Error(), "approved state-I/O owners or tests") {
		t.Fatalf("run() error = %v, want state import boundary failure", err)
	}
}

func TestRunRejectsDirectGateStateLiteralOutsideStateAndTests(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "internal/cli/bad.go", `package cli

const path = "gate-state.json"
`)

	err := run(root)
	if err == nil || !strings.Contains(err.Error(), "direct gate-state.json literal") {
		t.Fatalf("run() error = %v, want gate-state literal failure", err)
	}
}

func TestRunRejectsLegacyDebateSymbolsInV2SourceRoots(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "internal/cli/bad.go", `package cli

const duplicate = "_rdc_aggregate_and_promote"
`)

	err := run(root)
	if err == nil || !strings.Contains(err.Error(), "duplicates internal Go ownership") {
		t.Fatalf("run() error = %v, want legacy debate symbol failure", err)
	}
}

func TestRunAllowsOrchestratorAndTestImports(t *testing.T) {
	root := t.TempDir()
	writeFile(t, root, "internal/orchestrator/round.go", `package orchestrator

import "github.com/charlieyou/cerberus/internal/aggregate"

var _ = aggregate.ModeMajority
`)
	writeFile(t, root, "internal/cli/spawn_code_review_test.go", `package cli

import "github.com/charlieyou/cerberus/internal/anonymize"

var _ anonymize.PeerRecord
`)
	writeFile(t, root, "internal/cli/status.go", `package cli

import "github.com/charlieyou/cerberus/internal/state"

var _ = state.StatusPending
`)

	if err := run(root); err != nil {
		t.Fatalf("run() error = %v, want nil", err)
	}
}

func writeFile(t *testing.T, root, name, body string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll(%s): %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("WriteFile(%s): %v", path, err)
	}
}

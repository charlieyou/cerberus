package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLintGoFileRejectsComposedGateStateFilename(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "writer.go")
	source := `package sample

import (
	"os"
	"path/filepath"
)

func writeGate(runRoot string, data []byte) error {
	return os.WriteFile(filepath.Join(runRoot, "gate-state"+".json"), data, 0o644)
}
`
	if err := os.WriteFile(path, []byte(source), 0o644); err != nil {
		t.Fatalf("WriteFile(test source) error = %v", err)
	}

	failures := lintGoFile("internal/hook/writer.go", path)
	if len(failures) != 1 {
		t.Fatalf("len(failures) = %d, want 1: %v", len(failures), failures)
	}
	if !strings.Contains(failures[0], "direct gate-state.json literal") {
		t.Fatalf("failure = %q, want gate-state.json literal failure", failures[0])
	}
}

func TestLintGoFileRejectsParenthesizedComposedGateStateFilename(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "writer.go")
	source := `package sample

import (
	"os"
	"path/filepath"
)

func writeGate(runRoot string, data []byte) error {
	return os.WriteFile(filepath.Join(runRoot, ("gate-state"+".json")), data, 0o644)
}
`
	if err := os.WriteFile(path, []byte(source), 0o644); err != nil {
		t.Fatalf("WriteFile(test source) error = %v", err)
	}

	failures := lintGoFile("internal/hook/writer.go", path)
	if len(failures) != 1 {
		t.Fatalf("len(failures) = %d, want 1: %v", len(failures), failures)
	}
	if !strings.Contains(failures[0], "direct gate-state.json literal") {
		t.Fatalf("failure = %q, want gate-state.json literal failure", failures[0])
	}
}

func TestLintGoFileAllowsSplitGateStateSubstrings(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "message.go")
	source := `package sample

const message = "gate-state" + " file"
`
	if err := os.WriteFile(path, []byte(source), 0o644); err != nil {
		t.Fatalf("WriteFile(test source) error = %v", err)
	}

	if failures := lintGoFile("internal/hook/message.go", path); len(failures) != 0 {
		t.Fatalf("failures = %v, want none", failures)
	}
}

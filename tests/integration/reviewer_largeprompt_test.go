package integration_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/charlieyou/cerberus/internal/reviewer"
)

func TestReviewerLargePromptRoundTripUsesStdin(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "config"), 0o755); err != nil {
		t.Fatalf("MkdirAll(config) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "config", "gemini-readonly-policy.toml"), []byte("# policy\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(policy) error = %v", err)
	}

	recordDir := t.TempDir()
	userPrompt := bytes.Repeat([]byte("x"), 256*1024+1024)
	wantHash := fmt.Sprintf("%x", sha256.Sum256(userPrompt))

	t.Setenv("CERBERUS_MOCK_RECORD_DIR", recordDir)
	t.Setenv("PATH", filepath.Join(repoRoot, "tests", "mocks")+string(os.PathListSeparator)+os.Getenv("PATH"))

	response, err := (reviewer.Runner{Root: root, RunRoot: filepath.Join(t.TempDir(), "run"), Iteration: 1, Round: 1}).Spawn(context.Background(), reviewer.Request{
		ID:       "codex#1",
		Provider: "codex",
		Model:    "mock",
		System:   []byte("system"),
		User:     userPrompt,
	})
	if err != nil {
		t.Fatalf("Spawn() error = %v", err)
	}
	if response.Parsed == nil || response.Parsed.Verdict != "PASS" {
		t.Fatalf("parsed response = %#v, want PASS", response.Parsed)
	}

	stdinBytes, err := os.ReadFile(filepath.Join(recordDir, "codex.stdin"))
	if err != nil {
		t.Fatalf("ReadFile(codex.stdin) error = %v", err)
	}
	gotHash := fmt.Sprintf("%x", sha256.Sum256(stdinBytes))
	if gotHash != wantHash {
		t.Fatalf("stdin sha256 = %s, want %s", gotHash, wantHash)
	}

	args, err := os.ReadFile(filepath.Join(recordDir, "codex.args"))
	if err != nil {
		t.Fatalf("ReadFile(codex.args) error = %v", err)
	}
	if bytes.Contains(args, userPrompt[:1024]) {
		t.Fatal("argv contains the user prompt body; prompt must be sent via stdin")
	}
}

package reviewer

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunnerCommandConstructionAndStdinForProviders(t *testing.T) {
	for _, provider := range []string{"claude", "codex", "gemini"} {
		t.Run(provider, func(t *testing.T) {
			root := t.TempDir()
			writePolicy(t, root)
			recordDir := t.TempDir()
			t.Setenv("CERBERUS_MOCK_RECORD_DIR", recordDir)
			t.Setenv("PATH", mockPath(t)+string(os.PathListSeparator)+os.Getenv("PATH"))

			response, err := (Runner{
				Root:      root,
				RunRoot:   filepath.Join(t.TempDir(), "run"),
				Iteration: 2,
				Round:     3,
			}).Spawn(context.Background(), Request{
				ID:       provider + "#1",
				Provider: provider,
				Model:    "model-name",
				System:   []byte("system prompt"),
				User:     []byte("large user prompt body"),
			})
			if err != nil {
				t.Fatalf("Spawn() error = %v", err)
			}
			if response.Parsed == nil || response.Parsed.Verdict != "PASS" {
				t.Fatalf("parsed response = %#v, want PASS", response.Parsed)
			}

			args := readRecord(t, recordDir, provider+".args")
			if strings.Contains(args, "large user prompt body") {
				t.Fatalf("argv contains user prompt: %q", args)
			}
			stdin := readRecord(t, recordDir, provider+".stdin")
			if stdin != "large user prompt body" {
				t.Fatalf("stdin = %q, want user prompt", stdin)
			}
			if !strings.Contains(args, "--append-system-prompt\nsystem prompt") {
				t.Fatalf("argv = %q, want system prompt flag", args)
			}
			if provider == "gemini" {
				wantPolicy := filepath.Join(root, "config", "gemini-readonly-policy.toml")
				if !strings.Contains(args, "--policy-file\n"+wantPolicy) {
					t.Fatalf("gemini argv = %q, want policy file %s", args, wantPolicy)
				}
			}
		})
	}
}

func TestRunnerGeminiMissingPolicyFileFailsPreflight(t *testing.T) {
	t.Setenv("PATH", mockPath(t)+string(os.PathListSeparator)+os.Getenv("PATH"))
	_, err := (Runner{Root: t.TempDir()}).Spawn(context.Background(), Request{
		ID:       "gemini#1",
		Provider: "gemini",
		Model:    "model-name",
		System:   []byte("system"),
		User:     []byte("user"),
	})
	if err == nil {
		t.Fatal("Spawn() error = nil, want missing policy error")
	}
	if !strings.Contains(err.Error(), "gemini policy file") {
		t.Fatalf("Spawn() error = %q, want policy file message", err)
	}
}

func TestRunnerEmptyStdoutFails(t *testing.T) {
	root := t.TempDir()
	writePolicy(t, root)
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())
	t.Setenv("CERBERUS_MOCK_EMPTY_STDOUT", "1")
	t.Setenv("PATH", mockPath(t)+string(os.PathListSeparator)+os.Getenv("PATH"))

	_, err := (Runner{Root: root}).Spawn(context.Background(), Request{
		ID:       "codex#1",
		Provider: "codex",
		Model:    "model-name",
		System:   []byte("system"),
		User:     []byte("user"),
	})
	if err == nil {
		t.Fatal("Spawn() error = nil, want empty stdout error")
	}
	if !strings.Contains(err.Error(), "stdout is empty") {
		t.Fatalf("Spawn() error = %q, want empty stdout message", err)
	}
}

func TestRunnerNonZeroExitFails(t *testing.T) {
	root := t.TempDir()
	writePolicy(t, root)
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())
	t.Setenv("CERBERUS_MOCK_EXIT", "7")
	t.Setenv("PATH", mockPath(t)+string(os.PathListSeparator)+os.Getenv("PATH"))

	_, err := (Runner{Root: root}).Spawn(context.Background(), Request{
		ID:       "claude#1",
		Provider: "claude",
		Model:    "model-name",
		System:   []byte("system"),
		User:     []byte("user"),
	})
	if err == nil {
		t.Fatal("Spawn() error = nil, want non-zero exit error")
	}
	if !strings.Contains(err.Error(), "reviewer claude#1 failed") {
		t.Fatalf("Spawn() error = %q, want reviewer failure message", err)
	}
}

func TestRunnerWritesReviewerArtifacts(t *testing.T) {
	root := t.TempDir()
	writePolicy(t, root)
	runRoot := filepath.Join(t.TempDir(), "project", "run")
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())
	t.Setenv("PATH", mockPath(t)+string(os.PathListSeparator)+os.Getenv("PATH"))

	_, err := (Runner{Root: root, RunRoot: runRoot, Iteration: 4, Round: 2}).Spawn(context.Background(), Request{
		ID:       "codex#1",
		Provider: "codex",
		Model:    "model-name",
		System:   []byte("system"),
		User:     []byte("user prompt"),
	})
	if err != nil {
		t.Fatalf("Spawn() error = %v", err)
	}
	reviewerDir := filepath.Join(runRoot, "iterations", "4", "round-2", "reviewers", "codex#1")
	for _, name := range []string{"prompt.md", "output.json", "stdout.log", "stderr.log"} {
		if _, err := os.Stat(filepath.Join(reviewerDir, name)); err != nil {
			t.Fatalf("expected reviewer artifact %s: %v", name, err)
		}
	}
	if got := readRecord(t, reviewerDir, "prompt.md"); got != "user prompt" {
		t.Fatalf("prompt.md = %q, want user prompt", got)
	}
}

func TestParseRejectsInvalidJSONAndVerdict(t *testing.T) {
	if _, err := Parse([]byte(`not-json`)); err == nil {
		t.Fatal("Parse(invalid JSON) error = nil")
	}
	if _, err := Parse([]byte(`{"findings":[],"verdict":"pass","summary":"bad"}`)); err == nil {
		t.Fatal("Parse(invalid verdict) error = nil")
	}
}

func mockPath(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs(filepath.Join("..", "..", "tests", "mocks"))
	if err != nil {
		t.Fatalf("Abs(tests/mocks) error = %v", err)
	}
	return abs
}

func writePolicy(t *testing.T, root string) {
	t.Helper()
	path := filepath.Join(root, "config", "gemini-readonly-policy.toml")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll(policy dir) error = %v", err)
	}
	if err := os.WriteFile(path, []byte("# policy\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(policy) error = %v", err)
	}
}

func readRecord(t *testing.T, dir, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", name, err)
	}
	return string(data)
}

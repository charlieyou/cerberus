package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadProviderPromptSelectsOnlyMatchingProvider(t *testing.T) {
	dir := t.TempDir()
	for _, provider := range providers {
		if err := os.WriteFile(filepath.Join(dir, provider+".txt"), []byte(provider+" prompt"), 0o644); err != nil {
			t.Fatalf("WriteFile(%s) error = %v", provider, err)
		}
	}

	body, err := readProviderPrompt(dir, "codex")
	if err != nil {
		t.Fatalf("readProviderPrompt() error = %v", err)
	}
	if string(body) != "codex prompt" {
		t.Fatalf("readProviderPrompt() = %q, want provider-specific prompt", body)
	}
}

func TestReviewerPromptIncludesArtifactAndReviewerJSONShape(t *testing.T) {
	root := repoRoot(t)
	prompt, err := reviewerPrompt(root, "codex", "gpt-5.5", "codex#1", []byte("synthetic fixture artifact"))
	if err != nil {
		t.Fatalf("reviewerPrompt() error = %v", err)
	}
	text := string(prompt)
	for _, want := range []string{"synthetic fixture artifact", `"findings"`, `"verdict"`, `"overall_confidence"`} {
		if !strings.Contains(text, want) {
			t.Fatalf("reviewerPrompt() missing %q", want)
		}
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd() error = %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("repo root not found")
		}
		dir = parent
	}
}

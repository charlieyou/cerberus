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
	system, prompt, err := reviewerPrompt(root, "codex", "gpt-5.5", "codex#1", []byte("synthetic fixture artifact"))
	if err != nil {
		t.Fatalf("reviewerPrompt() error = %v", err)
	}
	if !strings.Contains(string(system), "Walk through the artifact") {
		t.Fatalf("reviewerPrompt() system = %q, want strategy guidance", system)
	}
	text := string(prompt)
	for _, want := range []string{"synthetic fixture artifact", `"findings"`, `"verdict"`, `"overall_confidence"`} {
		if !strings.Contains(text, want) {
			t.Fatalf("reviewerPrompt() missing %q", want)
		}
	}
}

func TestBuildRefreshRequestKeysRawPromptButSendsReviewerPrompt(t *testing.T) {
	root := repoRoot(t)
	dir := t.TempDir()
	rawPrompt := []byte("mock smoke prompt for codex\n")
	if err := os.WriteFile(filepath.Join(dir, "codex.txt"), rawPrompt, 0o644); err != nil {
		t.Fatalf("WriteFile(codex prompt) error = %v", err)
	}

	request, err := buildRefreshRequest(root, dir, "codex")
	if err != nil {
		t.Fatalf("buildRefreshRequest() error = %v", err)
	}
	if got, want := request.FixtureKey, fixtureKey(rawPrompt, "codex#1"); got != want {
		t.Fatalf("FixtureKey = %q, want raw prompt key %q", got, want)
	}
	if string(request.User) == string(rawPrompt) {
		t.Fatalf("User prompt was not composed")
	}
	for _, want := range []string{"mock smoke prompt for codex", `"findings"`, `"verdict"`} {
		if !strings.Contains(string(request.User), want) {
			t.Fatalf("User prompt missing %q", want)
		}
	}
	if len(request.System) == 0 {
		t.Fatalf("System prompt is empty")
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

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

func TestBuildRefreshRequestKeysAndSendsRawPrompt(t *testing.T) {
	dir := t.TempDir()
	rawPrompt := []byte("mock smoke prompt for codex\n")
	if err := os.WriteFile(filepath.Join(dir, "codex.txt"), rawPrompt, 0o644); err != nil {
		t.Fatalf("WriteFile(codex prompt) error = %v", err)
	}

	request, err := buildRefreshRequest(dir, "codex")
	if err != nil {
		t.Fatalf("buildRefreshRequest() error = %v", err)
	}
	if got, want := request.FixtureKey, fixtureKey(rawPrompt, "codex#1"); got != want {
		t.Fatalf("FixtureKey = %q, want raw prompt key %q", got, want)
	}
	if string(request.User) != string(rawPrompt) {
		t.Fatalf("User = %q, want raw prompt %q", request.User, rawPrompt)
	}
	if strings.Contains(string(request.System), string(rawPrompt)) {
		t.Fatalf("System prompt contains raw prompt bytes")
	}
	for _, want := range []string{`"findings"`, `"verdict"`, `"overall_confidence"`} {
		if !strings.Contains(string(request.System), want) {
			t.Fatalf("System prompt missing %q", want)
		}
	}
	if len(request.System) == 0 {
		t.Fatalf("System prompt is empty")
	}
}

func TestBuildRefreshRequestKeepsLargePromptOutOfSystemArg(t *testing.T) {
	dir := t.TempDir()
	rawPrompt := []byte(strings.Repeat("large prompt ", 32*1024))
	if err := os.WriteFile(filepath.Join(dir, "gemini.txt"), rawPrompt, 0o644); err != nil {
		t.Fatalf("WriteFile(gemini prompt) error = %v", err)
	}

	request, err := buildRefreshRequest(dir, "gemini")
	if err != nil {
		t.Fatalf("buildRefreshRequest() error = %v", err)
	}
	if string(request.User) != string(rawPrompt) {
		t.Fatalf("User prompt was not preserved")
	}
	if strings.Contains(string(request.System), "large prompt large prompt") {
		t.Fatalf("System prompt contains large stdin content")
	}
	if len(request.System) > 2048 {
		t.Fatalf("System prompt length = %d, want small argv payload", len(request.System))
	}
}

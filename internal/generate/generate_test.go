package generate

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestGenerateRunWritesProviderDrafts(t *testing.T) {
	root := t.TempDir()
	writeGeneratorPolicy(t, root)
	writeGeneratePrompt(t, root, "prompts/interview-engine.md", "interview")
	writeGeneratePrompt(t, root, "prompts/generators/create-spec.md", "create spec generator")

	binDir := t.TempDir()
	for _, provider := range []string{"claude", "codex", "gemini"} {
		writeMockProvider(t, binDir, provider, "")
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	recordDir := t.TempDir()
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", recordDir)

	promptFile := filepath.Join(t.TempDir(), "prompt.md")
	if err := os.WriteFile(promptFile, []byte("fixture prompt"), 0o644); err != nil {
		t.Fatalf("WriteFile(prompt) error = %v", err)
	}
	outputDir := t.TempDir()

	err := Run(context.Background(), Options{
		OutputDir:  outputDir,
		Type:       "create-spec",
		Mode:       "smart",
		PromptFile: promptFile,
		Root:       root,
	})
	if err != nil {
		t.Fatalf("Run() error = %v", err)
	}

	for _, provider := range []string{"claude", "codex", "gemini"} {
		path := filepath.Join(outputDir, provider, "draft.md")
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("ReadFile(%s) error = %v", path, err)
		}
		want := "# " + provider + " draft\n"
		if string(got) != want {
			t.Fatalf("%s = %q, want %q", path, got, want)
		}
	}
	assertNoRecordedModel(t, recordDir, "claude")
	assertRecordedModel(t, recordDir, "codex", "gpt-5.5")
	assertRecordedModel(t, recordDir, "gemini", "gemini-3.1-pro")
	assertJSONOutputFlag(t, recordDir, "codex")
	assertJSONOutputFlag(t, recordDir, "gemini")
}

func TestGenerateRunFansOutInParallel(t *testing.T) {
	root := t.TempDir()
	writeGeneratorPolicy(t, root)
	writeGeneratePrompt(t, root, "prompts/interview-engine.md", "interview")
	writeGeneratePrompt(t, root, "prompts/generators/create-plan.md", "create plan generator")

	originalRunner := providerRunner
	providerRunner = func(ctx context.Context, root, providerName, model, systemPrompt, userPrompt string) ([]byte, []byte, error) {
		time.Sleep(100 * time.Millisecond)
		return []byte("# " + providerName + " draft\n"), nil, nil
	}
	t.Cleanup(func() {
		providerRunner = originalRunner
	})

	start := time.Now()
	err := Run(context.Background(), Options{
		OutputDir:     t.TempDir(),
		Type:          "create-plan",
		Mode:          "smart",
		Prompt:        "fixture prompt",
		Root:          root,
		SkipInterview: true,
	})
	if err != nil {
		t.Fatalf("Run() error = %v", err)
	}
	if elapsed := time.Since(start); elapsed >= 200*time.Millisecond {
		t.Fatalf("Run() elapsed = %s, want parallel fan-out under 200ms", elapsed)
	}
}

func TestGenerateRunReturnsSubprocessError(t *testing.T) {
	root := t.TempDir()
	writeGeneratorPolicy(t, root)
	writeGeneratePrompt(t, root, "prompts/generators/healthcheck.md", "healthcheck generator")

	binDir := t.TempDir()
	writeMockProvider(t, binDir, "claude", "")
	writeMockProvider(t, binDir, "gemini", "")
	writeFailingProvider(t, binDir, "codex")
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())

	err := Run(context.Background(), Options{
		OutputDir: t.TempDir(),
		Type:      "healthcheck",
		Mode:      "smart",
		Prompt:    "fixture prompt",
		Root:      root,
	})
	if err == nil {
		t.Fatal("Run() error = nil, want subprocess failure")
	}
	if !strings.Contains(err.Error(), "generator codex failed") {
		t.Fatalf("Run() error = %q, want codex failure", err)
	}
}

func writeGeneratePrompt(t *testing.T, root, rel, content string) {
	t.Helper()
	path := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll(%s) error = %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content+"\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

func writeMockProvider(t *testing.T, dir, provider, delay string) {
	t.Helper()
	path := filepath.Join(dir, provider)
	body := "#!/bin/sh\nset -eu\ncat >/dev/null\n" + delay + "printf '%s\\n' \"$@\" > \"$CERBERUS_MOCK_RECORD_DIR/" + provider + ".args\"\nprintf '# " + provider + " draft\\n'\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

func assertNoRecordedModel(t *testing.T, recordDir, provider string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(recordDir, provider+".args"))
	if err != nil {
		t.Fatalf("ReadFile(%s args) error = %v", provider, err)
	}
	if strings.Contains(string(data), "--model\n") {
		t.Fatalf("%s args = %q, want no model flag", provider, data)
	}
}

func assertRecordedModel(t *testing.T, recordDir, provider, want string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(recordDir, provider+".args"))
	if err != nil {
		t.Fatalf("ReadFile(%s args) error = %v", provider, err)
	}
	if !strings.Contains(string(data), "--model\n"+want+"\n") {
		t.Fatalf("%s args = %q, want model %q", provider, data, want)
	}
	if strings.Contains(string(data), "--model\nmock\n") {
		t.Fatalf("%s args = %q, must not use mock model", provider, data)
	}
}

func assertJSONOutputFlag(t *testing.T, recordDir, provider string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(recordDir, provider+".args"))
	if err != nil {
		t.Fatalf("ReadFile(%s args) error = %v", provider, err)
	}
	if !strings.Contains(string(data), "--json\n") {
		t.Fatalf("%s args = %q, want JSON output flag", provider, data)
	}
}

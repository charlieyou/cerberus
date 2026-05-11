package generate

import (
	"bytes"
	"context"
	"encoding/json"
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
		stats := readStatsFile(t, filepath.Join(outputDir, provider, "stats.json"))
		if stats.ExitCode != 0 {
			t.Fatalf("%s stats exit_code = %d, want 0", provider, stats.ExitCode)
		}
		if stats.ErrorMessage != "" {
			t.Fatalf("%s stats error_message = %q, want empty", provider, stats.ErrorMessage)
		}
		if _, err := os.Stat(filepath.Join(outputDir, provider+".failed")); !os.IsNotExist(err) {
			t.Fatalf("%s failed marker stat err = %v, want not exist", provider, err)
		}
		if _, err := os.Stat(filepath.Join(outputDir, provider, "raw.json")); !os.IsNotExist(err) {
			t.Fatalf("%s raw.json stat err = %v, want not exist for markdown stdout", provider, err)
		}
	}
	assertNoRecordedModel(t, recordDir, "claude")
	assertRecordedModel(t, recordDir, "codex", "gpt-5.5")
	assertRecordedModel(t, recordDir, "gemini", "gemini-3.1-pro-preview")
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

func TestGenerateRunWritesRawJSONForParseableProviderOutput(t *testing.T) {
	root := t.TempDir()
	writeGeneratorPolicy(t, root)
	writeGeneratePrompt(t, root, "prompts/generators/create-plan.md", "create plan generator")

	originalRunner := providerRunner
	providerRunner = func(ctx context.Context, root, providerName, model, systemPrompt, userPrompt string) ([]byte, []byte, error) {
		return []byte(`{"usage":{"input_tokens":7,"output_tokens":3},"cost_usd":0.001}`), nil, nil
	}
	t.Cleanup(func() {
		providerRunner = originalRunner
	})

	outputDir := t.TempDir()
	err := Run(context.Background(), Options{
		OutputDir:     outputDir,
		Type:          "create-plan",
		Mode:          "smart",
		Prompt:        "fixture prompt",
		Root:          root,
		Providers:     []string{"codex"},
		SkipInterview: true,
	})
	if err != nil {
		t.Fatalf("Run() error = %v", err)
	}
	raw := filepath.Join(outputDir, "codex", "raw.json")
	assertFileContent(t, raw, `{"usage":{"input_tokens":7,"output_tokens":3},"cost_usd":0.001}`)
	stats := readStatsFile(t, filepath.Join(outputDir, "codex", "stats.json"))
	if stats.Tokens == nil || stats.Tokens.Input != 7 || stats.Tokens.Output != 3 {
		t.Fatalf("stats tokens = %#v, want input=7 output=3", stats.Tokens)
	}
}

func TestRunPartialFailureReturnsNilAndWritesFailureOutputs(t *testing.T) {
	root := t.TempDir()
	writeGeneratorPolicy(t, root)
	writeGeneratePrompt(t, root, "prompts/generators/healthcheck.md", "healthcheck generator")

	binDir := t.TempDir()
	writeMockProvider(t, binDir, "claude", "")
	writeMockProvider(t, binDir, "gemini", "")
	writeFailingProvider(t, binDir, "codex")
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())
	outputDir := t.TempDir()
	var stderr bytes.Buffer

	err := Run(context.Background(), Options{
		OutputDir: outputDir,
		Type:      "healthcheck",
		Mode:      "smart",
		Prompt:    "fixture prompt",
		Root:      root,
		Stderr:    &stderr,
	})
	if err != nil {
		t.Fatalf("Run() error = %v, want nil for partial failure", err)
	}
	if !strings.Contains(stderr.String(), "cerberus generate: 2 providers succeeded, 1 failed (codex.failed)") {
		t.Fatalf("stderr = %q, want partial failure summary", stderr.String())
	}
	assertFileContent(t, filepath.Join(outputDir, "claude", "draft.md"), "# claude draft\n")
	assertFileContent(t, filepath.Join(outputDir, "gemini", "draft.md"), "# gemini draft\n")
	if _, err := os.Stat(filepath.Join(outputDir, "codex", "draft.md")); !os.IsNotExist(err) {
		t.Fatalf("codex draft stat err = %v, want not exist", err)
	}
	assertFileContent(t, filepath.Join(outputDir, "codex.failed"), "generator codex failed: exit status 9; stderr: failure stderr\n")
	for _, provider := range []string{"claude", "codex", "gemini"} {
		stats := readStatsFile(t, filepath.Join(outputDir, provider, "stats.json"))
		if provider == "codex" {
			if stats.ExitCode != 9 {
				t.Fatalf("codex exit_code = %d, want 9", stats.ExitCode)
			}
			if !strings.Contains(stats.ErrorMessage, "generator codex failed") {
				t.Fatalf("codex error_message = %q, want failure", stats.ErrorMessage)
			}
			continue
		}
		if stats.ExitCode != 0 {
			t.Fatalf("%s exit_code = %d, want 0", provider, stats.ExitCode)
		}
	}
}

func TestRunAllFailureReturnsErrorAndWritesFailureOutputs(t *testing.T) {
	root := t.TempDir()
	writeGeneratorPolicy(t, root)
	writeGeneratePrompt(t, root, "prompts/generators/healthcheck.md", "healthcheck generator")

	binDir := t.TempDir()
	for _, provider := range []string{"claude", "codex", "gemini"} {
		writeFailingProvider(t, binDir, provider)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())
	outputDir := t.TempDir()
	var stderr bytes.Buffer

	err := Run(context.Background(), Options{
		OutputDir: outputDir,
		Type:      "healthcheck",
		Mode:      "smart",
		Prompt:    "fixture prompt",
		Root:      root,
		Stderr:    &stderr,
	})
	if err == nil {
		t.Fatal("Run() error = nil, want all-provider failure")
	}
	if !strings.Contains(err.Error(), "all providers failed") {
		t.Fatalf("Run() error = %q, want all providers failed", err)
	}
	if !strings.Contains(stderr.String(), "cerberus generate: 0 providers succeeded, 3 failed (claude.failed, codex.failed, gemini.failed)") {
		t.Fatalf("stderr = %q, want all failure summary", stderr.String())
	}
	for _, provider := range []string{"claude", "codex", "gemini"} {
		if _, err := os.Stat(filepath.Join(outputDir, provider, "draft.md")); !os.IsNotExist(err) {
			t.Fatalf("%s draft stat err = %v, want not exist", provider, err)
		}
		if _, err := os.Stat(filepath.Join(outputDir, provider+".failed")); err != nil {
			t.Fatalf("%s failed marker stat err = %v, want exist", provider, err)
		}
		stats := readStatsFile(t, filepath.Join(outputDir, provider, "stats.json"))
		if stats.ExitCode != 9 {
			t.Fatalf("%s exit_code = %d, want 9", provider, stats.ExitCode)
		}
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
	want := "--json\n"
	if provider == "gemini" {
		want = "--output-format\njson\n"
	}
	if !strings.Contains(string(data), want) {
		t.Fatalf("%s args = %q, want JSON output flag %q", provider, data, want)
	}
}

func readStatsFile(t *testing.T, path string) Stats {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	var stats Stats
	if err := json.Unmarshal(data, &stats); err != nil {
		t.Fatalf("Unmarshal(%s) error = %v; data=%s", path, err, data)
	}
	return stats
}

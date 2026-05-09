package generate

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGenerateRunWritesProviderDrafts(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "config"), 0o755); err != nil {
		t.Fatalf("MkdirAll(config) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "config", "gemini-readonly-policy.toml"), []byte("# policy\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(policy) error = %v", err)
	}

	binDir := t.TempDir()
	for _, provider := range []string{"claude", "codex", "gemini"} {
		writeMockProvider(t, binDir, provider)
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
	assertRecordedModel(t, recordDir, "claude", "claude-opus-4-7")
	assertRecordedModel(t, recordDir, "codex", "gpt-5.5")
	assertRecordedModel(t, recordDir, "gemini", "gemini-3.1-pro")
	assertNoJSONOutputFlag(t, recordDir, "codex")
	assertNoJSONOutputFlag(t, recordDir, "gemini")
}

func writeMockProvider(t *testing.T, dir, provider string) {
	t.Helper()
	path := filepath.Join(dir, provider)
	body := "#!/bin/sh\nset -eu\ncat >/dev/null\nprintf '%s\\n' \"$@\" > \"$CERBERUS_MOCK_RECORD_DIR/" + provider + ".args\"\nprintf '# " + provider + " draft\\n'\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
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

func assertNoJSONOutputFlag(t *testing.T, recordDir, provider string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(recordDir, provider+".args"))
	if err != nil {
		t.Fatalf("ReadFile(%s args) error = %v", provider, err)
	}
	if strings.Contains(string(data), "--json\n") {
		t.Fatalf("%s args = %q, must not request JSON output for draft generation", provider, data)
	}
}

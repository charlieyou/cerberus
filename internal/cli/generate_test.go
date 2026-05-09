package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGenerateSubcommandRejectsMissingArgs(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run([]string{"generate"}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("run(generate) exit code = 0, want non-zero")
	}
	if stdout.Len() != 0 {
		t.Fatalf("run(generate) stdout = %q, want empty", stdout.String())
	}
	if got := stderr.String(); !bytes.Contains([]byte(got), []byte("usage: cerberus generate")) {
		t.Fatalf("run(generate) stderr = %q, want usage", got)
	}
}

func TestGenerateSubcommand(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "config"), 0o755); err != nil {
		t.Fatalf("MkdirAll(config) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "config", "gemini-readonly-policy.toml"), []byte("# policy\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(policy) error = %v", err)
	}
	projectDir := t.TempDir()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd() error = %v", err)
	}
	if err := os.Chdir(projectDir); err != nil {
		t.Fatalf("Chdir(projectDir) error = %v", err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(wd); err != nil {
			t.Fatalf("restore working directory: %v", err)
		}
	})
	t.Setenv("CERBERUS_ROOT", root)

	binDir := t.TempDir()
	for _, provider := range []string{"claude", "codex", "gemini"} {
		writeGenerateCLIMockProvider(t, binDir, provider)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	promptFile := filepath.Join(t.TempDir(), "prompt.md")
	if err := os.WriteFile(promptFile, []byte("fixture prompt"), 0o644); err != nil {
		t.Fatalf("WriteFile(prompt) error = %v", err)
	}
	outputDir := t.TempDir()

	var stdout, stderr bytes.Buffer
	code := run([]string{"generate", outputDir, "--type", "create-spec", "--mode", "smart", "--prompt-file", promptFile}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("run(generate) exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("run(generate) stdout = %q, want empty", stdout.String())
	}
	for _, provider := range []string{"claude", "codex", "gemini"} {
		path := filepath.Join(outputDir, provider, "draft.md")
		if got, err := os.ReadFile(path); err != nil || len(got) == 0 {
			t.Fatalf("draft %s read = %q, %v; want non-empty", provider, got, err)
		}
	}
}

func TestGenerateSubcommandUsesDefaultModels(t *testing.T) {
	opts, err := parseGenerateFlags([]string{t.TempDir(), "--type", "create-spec", "--prompt-file", "prompt.md"}, &bytes.Buffer{})
	if err != nil {
		t.Fatalf("parseGenerateFlags() error = %v", err)
	}
	if opts.Root != "" {
		t.Fatalf("parseGenerateFlags() Root = %q, want empty before runGenerate resolves env", opts.Root)
	}

	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "config"), 0o755); err != nil {
		t.Fatalf("MkdirAll(config) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "config", "gemini-readonly-policy.toml"), []byte("# policy\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(policy) error = %v", err)
	}
	t.Setenv("CERBERUS_ROOT", root)
	recordDir := t.TempDir()
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", recordDir)

	binDir := t.TempDir()
	for _, provider := range []string{"claude", "codex", "gemini"} {
		writeGenerateCLIMockProvider(t, binDir, provider)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	promptFile := filepath.Join(t.TempDir(), "prompt.md")
	if err := os.WriteFile(promptFile, []byte("fixture prompt"), 0o644); err != nil {
		t.Fatalf("WriteFile(prompt) error = %v", err)
	}
	var stdout, stderr bytes.Buffer
	code := run([]string{"generate", t.TempDir(), "--type", "create-spec", "--prompt-file", promptFile}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run(generate) exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	assertGenerateRecordedModel(t, recordDir, "claude", "claude-opus-4-7")
	assertGenerateRecordedModel(t, recordDir, "codex", "gpt-5.5")
	assertGenerateRecordedModel(t, recordDir, "gemini", "gemini-3.1-pro")
}

func writeGenerateCLIMockProvider(t *testing.T, dir, provider string) {
	t.Helper()
	path := filepath.Join(dir, provider)
	body := "#!/bin/sh\nset -eu\ncat >/dev/null\nif [ -n \"${CERBERUS_MOCK_RECORD_DIR:-}\" ]; then printf '%s\\n' \"$@\" > \"$CERBERUS_MOCK_RECORD_DIR/" + provider + ".args\"; fi\nprintf '# " + provider + " cli draft\\n'\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

func assertGenerateRecordedModel(t *testing.T, recordDir, provider, want string) {
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

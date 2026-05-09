package cli

import (
	"bytes"
	"os"
	"path/filepath"
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
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd() error = %v", err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatalf("Chdir(root) error = %v", err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(wd); err != nil {
			t.Fatalf("restore working directory: %v", err)
		}
	})

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

func writeGenerateCLIMockProvider(t *testing.T, dir, provider string) {
	t.Helper()
	path := filepath.Join(dir, provider)
	body := "#!/bin/sh\ncat >/dev/null\nprintf '# " + provider + " cli draft\\n'\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

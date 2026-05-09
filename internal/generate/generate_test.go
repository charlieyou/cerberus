package generate

import (
	"context"
	"os"
	"path/filepath"
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
}

func writeMockProvider(t *testing.T, dir, provider string) {
	t.Helper()
	path := filepath.Join(dir, provider)
	body := "#!/bin/sh\ncat >/dev/null\nprintf '# " + provider + " draft\\n'\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

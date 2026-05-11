package integration_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestGeneratePath(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}

	binary := filepath.Join(t.TempDir(), "cerberus")
	build := exec.Command("go", "build", "-o", binary, "./cmd/cerberus")
	build.Dir = repoRoot
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build ./cmd/cerberus failed: %v\n%s", err, output)
	}

	promptFile := filepath.Join(t.TempDir(), "prompt.md")
	if err := os.WriteFile(promptFile, []byte("write a create-spec draft"), 0o644); err != nil {
		t.Fatalf("WriteFile(prompt) error = %v", err)
	}
	outputDir := t.TempDir()
	recordDir := t.TempDir()
	fixtureDir := keyedGenerateFixtureDir(t, repoRoot, "create-spec", "write a create-spec draft", generateProviders)

	cmd := exec.Command(binary, "generate", outputDir, "--type", "create-spec", "--mode", "smart", "--prompt-file", promptFile)
	cmd.Dir = t.TempDir()
	cmd.Env = append(os.Environ(),
		"CERBERUS_ROOT="+repoRoot,
		"CERBERUS_FIXTURE_DIR="+fixtureDir,
		"CERBERUS_MOCK_RECORD_DIR="+recordDir,
		"PATH="+integrationMockPath(t, repoRoot)+string(os.PathListSeparator)+os.Getenv("PATH"),
	)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("cerberus generate failed: %v\n%s", err, output)
	}

	for _, provider := range []string{"claude", "codex", "gemini"} {
		got, err := os.ReadFile(filepath.Join(outputDir, provider, "draft.md"))
		if err != nil {
			t.Fatalf("ReadFile(%s draft) error = %v", provider, err)
		}
		want, err := os.ReadFile(filepath.Join(repoRoot, "tests", "fixtures", "generate", provider+"-create-spec.md"))
		if err != nil {
			t.Fatalf("ReadFile(%s fixture) error = %v", provider, err)
		}
		if len(got) == 0 {
			t.Fatalf("%s draft is empty", provider)
		}
		if string(got) != string(want) {
			t.Fatalf("%s draft = %q, want fixture %q", provider, got, want)
		}
	}
}

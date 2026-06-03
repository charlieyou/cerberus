package prompts

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestComposeGeneratorReadsEditedTemplateFromDisk(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join("prompts", "generators", "create-spec", "codex.md")
	writePrompt(t, root, path, "old generator")

	got, err := ComposeGeneratorFromRoot(root, "codex", "create-spec")
	if err != nil {
		t.Fatalf("ComposeGeneratorFromRoot() error = %v", err)
	}
	if got != "old generator" {
		t.Fatalf("first prompt = %q, want old generator", got)
	}

	time.Sleep(time.Millisecond)
	writePrompt(t, root, path, "new generator")
	got, err = ComposeGeneratorFromRoot(root, "codex", "create-spec")
	if err != nil {
		t.Fatalf("ComposeGeneratorFromRoot() error = %v", err)
	}
	if got != "new generator" {
		t.Fatalf("second prompt = %q, want edited template", got)
	}
}

func TestComposeGeneratorFallsBackToFlatPreservedTemplate(t *testing.T) {
	root := t.TempDir()
	writePrompt(t, root, filepath.Join("prompts", "generators", "create-spec.md"), "flat generator")

	got, err := ComposeGeneratorFromRoot(root, "claude", "create-spec")
	if err != nil {
		t.Fatalf("ComposeGeneratorFromRoot() error = %v", err)
	}
	if got != "flat generator" {
		t.Fatalf("prompt = %q, want flat generator", got)
	}
}

func TestComposeGeneratorMissingTemplateFails(t *testing.T) {
	_, err := ComposeGeneratorFromRoot(t.TempDir(), "gemini", "create-plan")
	if err == nil {
		t.Fatal("ComposeGeneratorFromRoot() error = nil, want missing template error")
	}
}

func TestComposeGeneratorUsesCERBERUSRoot(t *testing.T) {
	root := t.TempDir()
	writePrompt(t, root, filepath.Join("prompts", "generators", "create-plan", "gemini.md"), "from env")
	t.Setenv("CERBERUS_ROOT", root)

	got, err := ComposeGenerator("gemini", "create-plan")
	if err != nil {
		t.Fatalf("ComposeGenerator() error = %v", err)
	}
	if got != "from env" {
		t.Fatalf("prompt = %q, want env-root template", got)
	}
}

func TestComposeGeneratorReadErrorIsLoud(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "prompts", "generators", "create-spec", "claude.md")
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("MkdirAll(%q) error = %v", path, err)
	}

	_, err := ComposeGeneratorFromRoot(root, "claude", "create-spec")
	if err == nil {
		t.Fatal("ComposeGeneratorFromRoot() error = nil, want read error")
	}
}

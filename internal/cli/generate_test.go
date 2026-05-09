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

func TestGenerateSubcommandRejectsInvalidType(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run([]string{"generate", t.TempDir(), "--type", "bogus", "prompt"}, &stdout, &stderr)

	if code != 2 {
		t.Fatalf("run(generate) exit code = %d, want 2; stderr: %s", code, stderr.String())
	}
	got := stderr.String()
	for _, want := range []string{"create-plan", "create-spec", "healthcheck", "architecture-review"} {
		if !strings.Contains(got, want) {
			t.Fatalf("run(generate) stderr = %q, want valid type %q", got, want)
		}
	}
}

func TestGenerateSubcommandRejectsMissingPromptFile(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing.md")
	var stdout, stderr bytes.Buffer

	code := run([]string{"generate", t.TempDir(), "--type", "create-spec", "--prompt-file", missing}, &stdout, &stderr)

	if code != 1 {
		t.Fatalf("run(generate) exit code = %d, want 1; stderr: %s", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), missing) {
		t.Fatalf("run(generate) stderr = %q, want missing prompt path", stderr.String())
	}
}

func TestGenerateSubcommandRejectsInvalidMode(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run([]string{"generate", t.TempDir(), "--type", "create-spec", "--mode", "slow", "prompt"}, &stdout, &stderr)

	if code != 2 {
		t.Fatalf("run(generate) exit code = %d, want 2; stderr: %s", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "fast, smart, max") {
		t.Fatalf("run(generate) stderr = %q, want valid modes", stderr.String())
	}
}

func TestGenerateSubcommandRejectsUnknownFlagOnce(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run([]string{"generate", t.TempDir(), "--unknown"}, &stdout, &stderr)

	if code != 2 {
		t.Fatalf("run(generate) exit code = %d, want 2; stderr: %s", code, stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("run(generate) stdout = %q, want empty", stdout.String())
	}
	got := stderr.String()
	if count := strings.Count(got, "flag provided but not defined: -unknown"); count != 1 {
		t.Fatalf("run(generate) flag error count = %d, want 1; stderr: %q", count, got)
	}
	if count := strings.Count(got, "usage: cerberus generate"); count != 1 {
		t.Fatalf("run(generate) usage count = %d, want 1; stderr: %q", count, got)
	}
}

func TestGenerateSubcommandRejectsMissingPromptInput(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run([]string{"generate", t.TempDir(), "--type", "create-spec"}, &stdout, &stderr)

	if code != 2 {
		t.Fatalf("run(generate) exit code = %d, want 2; stderr: %s", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "one of --prompt-file, --focus, or prompt text is required") {
		t.Fatalf("run(generate) stderr = %q, want missing prompt input message", stderr.String())
	}
}

func TestGenerateSubcommandRejectsOutputDirRegularFile(t *testing.T) {
	outputPath := filepath.Join(t.TempDir(), "output")
	if err := os.WriteFile(outputPath, []byte("not a directory"), 0o644); err != nil {
		t.Fatalf("WriteFile(output) error = %v", err)
	}
	var stdout, stderr bytes.Buffer

	code := run([]string{"generate", outputPath, "--type", "create-spec", "prompt"}, &stdout, &stderr)

	if code != 1 {
		t.Fatalf("run(generate) exit code = %d, want 1; stderr: %s", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "not a directory") {
		t.Fatalf("run(generate) stderr = %q, want not a directory", stderr.String())
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
	writeGenerateCLIPrompt(t, root, "prompts/generators/create-spec.md", "create spec generator")
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
	recordDir := t.TempDir()
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", recordDir)

	promptFile := filepath.Join(t.TempDir(), "prompt.md")
	prompt := strings.Repeat("x", 256*1024)
	if err := os.WriteFile(promptFile, []byte(prompt), 0o644); err != nil {
		t.Fatalf("WriteFile(prompt) error = %v", err)
	}
	outputDir := filepath.Join(t.TempDir(), "created-output")

	var stdout, stderr bytes.Buffer
	code := run([]string{"generate", outputDir, "--type", "create-spec", "--mode", "smart", "--prompt-file", promptFile, "--skip-interview"}, &stdout, &stderr)

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
	gotPrompt, err := os.ReadFile(filepath.Join(recordDir, "claude.stdin"))
	if err != nil {
		t.Fatalf("ReadFile(claude stdin) error = %v", err)
	}
	if string(gotPrompt) != prompt {
		t.Fatalf("claude stdin prompt length = %d, want %d", len(gotPrompt), len(prompt))
	}
}

func TestGenerateSubcommandUsesDefaultModels(t *testing.T) {
	promptFile := filepath.Join(t.TempDir(), "prompt.md")
	if err := os.WriteFile(promptFile, []byte("fixture prompt"), 0o644); err != nil {
		t.Fatalf("WriteFile(prompt) error = %v", err)
	}
	opts, err := parseGenerateFlags([]string{t.TempDir(), "--type", "create-spec", "--prompt-file", promptFile}, &bytes.Buffer{})
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
	writeGenerateCLIPrompt(t, root, "prompts/interview-engine.md", "interview")
	writeGenerateCLIPrompt(t, root, "prompts/generators/create-spec.md", "create spec generator")
	t.Setenv("CERBERUS_ROOT", root)
	recordDir := t.TempDir()
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", recordDir)

	binDir := t.TempDir()
	for _, provider := range []string{"claude", "codex", "gemini"} {
		writeGenerateCLIMockProvider(t, binDir, provider)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	promptFile = filepath.Join(t.TempDir(), "prompt.md")
	if err := os.WriteFile(promptFile, []byte("fixture prompt"), 0o644); err != nil {
		t.Fatalf("WriteFile(prompt) error = %v", err)
	}
	var stdout, stderr bytes.Buffer
	code := run([]string{"generate", t.TempDir(), "--type", "create-spec", "--prompt-file", promptFile}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run(generate) exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	assertGenerateNoRecordedModel(t, recordDir, "claude")
	assertGenerateRecordedModel(t, recordDir, "codex", "gpt-5.5")
	assertGenerateRecordedModel(t, recordDir, "gemini", "gemini-3.1-pro")
	assertGenerateJSONOutputFlag(t, recordDir, "codex")
	assertGenerateJSONOutputFlag(t, recordDir, "gemini")
}

func TestGenerateSubcommandFocusBecomesPrompt(t *testing.T) {
	opts, err := parseGenerateFlags([]string{t.TempDir(), "--type", "healthcheck", "--focus", "foo bar"}, &bytes.Buffer{})
	if err != nil {
		t.Fatalf("parseGenerateFlags() error = %v", err)
	}
	if opts.Focus != "foo bar" {
		t.Fatalf("Focus = %q, want foo bar", opts.Focus)
	}
	if opts.Prompt != "foo bar" {
		t.Fatalf("Prompt = %q, want foo bar", opts.Prompt)
	}
}

func TestGenerateSubcommandTrailingArgsBecomePrompt(t *testing.T) {
	opts, err := parseGenerateFlags([]string{t.TempDir(), "--type", "healthcheck", "focus", "on", "errors"}, &bytes.Buffer{})
	if err != nil {
		t.Fatalf("parseGenerateFlags() error = %v", err)
	}
	if opts.Prompt != "focus on errors" {
		t.Fatalf("Prompt = %q, want trailing args joined", opts.Prompt)
	}
}

func writeGenerateCLIMockProvider(t *testing.T, dir, provider string) {
	t.Helper()
	path := filepath.Join(dir, provider)
	body := "#!/bin/sh\nset -eu\nif [ -n \"${CERBERUS_MOCK_RECORD_DIR:-}\" ]; then cat > \"$CERBERUS_MOCK_RECORD_DIR/" + provider + ".stdin\"; printf '%s\\n' \"$@\" > \"$CERBERUS_MOCK_RECORD_DIR/" + provider + ".args\"; else cat >/dev/null; fi\nprintf '# " + provider + " cli draft\\n'\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

func writeGenerateCLIPrompt(t *testing.T, root, rel, content string) {
	t.Helper()
	path := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll(%s) error = %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content+"\n"), 0o644); err != nil {
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

func assertGenerateNoRecordedModel(t *testing.T, recordDir, provider string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(recordDir, provider+".args"))
	if err != nil {
		t.Fatalf("ReadFile(%s args) error = %v", provider, err)
	}
	if strings.Contains(string(data), "--model\n") {
		t.Fatalf("%s args = %q, want no model flag", provider, data)
	}
}

func assertGenerateJSONOutputFlag(t *testing.T, recordDir, provider string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(recordDir, provider+".args"))
	if err != nil {
		t.Fatalf("ReadFile(%s args) error = %v", provider, err)
	}
	if !strings.Contains(string(data), "--json\n") {
		t.Fatalf("%s args = %q, want JSON output flag", provider, data)
	}
}

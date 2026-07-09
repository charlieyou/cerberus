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
	for _, invalidType := range []string{"bogus", "healthcheck", "architecture-review"} {
		t.Run(invalidType, func(t *testing.T) {
			var stdout, stderr bytes.Buffer

			code := run([]string{"generate", t.TempDir(), "--type", invalidType, "prompt"}, &stdout, &stderr)

			if code != 2 {
				t.Fatalf("run(generate) exit code = %d, want 2; stderr: %s", code, stderr.String())
			}
			got := stderr.String()
			for _, want := range []string{"create-plan", "create-spec"} {
				if !strings.Contains(got, want) {
					t.Fatalf("run(generate) stderr = %q, want valid type %q", got, want)
				}
			}
			for _, removed := range []string{"healthcheck", "architecture-review"} {
				if strings.Contains(got, removed) {
					t.Fatalf("run(generate) stderr = %q, must not advertise removed type %q", got, removed)
				}
			}
		})
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

	if code != 1 {
		t.Fatalf("run(generate) exit code = %d, want 1; stderr: %s", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), `mode "slow"`) || !strings.Contains(stderr.String(), "mode is not defined under roster") {
		t.Fatalf("run(generate) stderr = %q, want undefined mode error", stderr.String())
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
	if strings.Contains(stderr.String(), "healthcheck") || strings.Contains(stderr.String(), "architecture-review") {
		t.Fatalf("run(generate) stderr = %q, must not advertise removed generator types", stderr.String())
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
	isolateRosters(t)
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
	for _, provider := range []string{"claude", "codex", "gemini"} {
		path := filepath.Join(outputDir, provider, "draft.md")
		if got, err := os.ReadFile(path); err != nil || len(got) == 0 {
			t.Fatalf("draft %s read = %q, %v; want non-empty", provider, got, err)
		}
		if !strings.Contains(stdout.String(), path) {
			t.Fatalf("run(generate) stdout = %q, want printed draft path %q", stdout.String(), path)
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
	isolateRosters(t)
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
	assertGenerateRecordedModel(t, recordDir, "claude", "opus[1m]")
	assertGenerateRecordedModel(t, recordDir, "codex", "gpt-5.6-sol")
	assertGenerateRecordedModel(t, recordDir, "gemini", "gemini-3.1-pro-preview")
	assertGenerateJSONOutputFlag(t, recordDir, "codex")
	assertGenerateJSONOutputFlag(t, recordDir, "gemini")
}

func TestGenerateSubcommandFocusBecomesPrompt(t *testing.T) {
	opts, err := parseGenerateFlags([]string{t.TempDir(), "--type", "create-spec", "--focus", "foo bar"}, &bytes.Buffer{})
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
	opts, err := parseGenerateFlags([]string{t.TempDir(), "--type", "create-plan", "focus", "on", "errors"}, &bytes.Buffer{})
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
	body := "#!/bin/sh\nset -eu\nif [ -n \"${CERBERUS_MOCK_RECORD_DIR:-}\" ]; then cat > \"$CERBERUS_MOCK_RECORD_DIR/" + provider + ".stdin\"; printf '%s\\n' \"$@\" > \"$CERBERUS_MOCK_RECORD_DIR/" + provider + ".args\"; if [ \"" + provider + "\" = gemini ] && [ -n \"${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-}\" ]; then cp \"$GEMINI_CLI_SYSTEM_SETTINGS_PATH\" \"$CERBERUS_MOCK_RECORD_DIR/" + provider + ".settings.json\"; fi; else cat >/dev/null; fi\nprintf '# " + provider + " cli draft\\n'\n"
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
	if provider == "gemini" {
		if !strings.Contains(string(data), "--model\ncerberus-reviewer\n") {
			t.Fatalf("gemini args = %q, want effort model alias", data)
		}
		settings, err := os.ReadFile(filepath.Join(recordDir, provider+".settings.json"))
		if err != nil {
			t.Fatalf("ReadFile(%s settings) error = %v", provider, err)
		}
		if !strings.Contains(string(settings), `"model": "`+want+`"`) {
			t.Fatalf("gemini settings = %q, want model %q", settings, want)
		}
		return
	}
	if !strings.Contains(string(data), "--model\n"+want+"\n") {
		t.Fatalf("%s args = %q, want model %q", provider, data, want)
	}
	if strings.Contains(string(data), "--model\nmock\n") {
		t.Fatalf("%s args = %q, must not use mock model", provider, data)
	}
}

func assertGenerateJSONOutputFlag(t *testing.T, recordDir, provider string) {
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

// isolateRosters points config discovery at empty temp dirs so generate falls
// back to its built-in default panel regardless of the developer's real
// ~/.cerberus or $XDG_CONFIG_HOME.
func isolateRosters(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
}

// writeInstanceRecordingMock writes a provider CLI mock that records stdin and
// argv keyed by CERBERUS_MOCK_INSTANCE_ID, so two instances of the same
// provider (codex, codex-2) record to distinct files.
func writeInstanceRecordingMock(t *testing.T, dir, provider string) {
	t.Helper()
	path := filepath.Join(dir, provider)
	body := "#!/bin/sh\nset -eu\nid=\"${CERBERUS_MOCK_INSTANCE_ID:-" + provider + "}\"\n" +
		"if [ -n \"${CERBERUS_MOCK_RECORD_DIR:-}\" ]; then cat > \"$CERBERUS_MOCK_RECORD_DIR/$id.stdin\"; printf '%s\\n' \"$@\" > \"$CERBERUS_MOCK_RECORD_DIR/$id.args\"; else cat >/dev/null; fi\n" +
		"printf '# %s draft\\n' \"$id\"\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

func TestGenerateSubcommandTwoCodexInstancesFromRoster(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "config"), 0o755); err != nil {
		t.Fatalf("MkdirAll(config) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "config", "gemini-readonly-policy.toml"), []byte("# policy\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(policy) error = %v", err)
	}
	writeGenerateCLIPrompt(t, root, "prompts/generators/create-spec.md", "create spec generator")
	t.Setenv("CERBERUS_ROOT", root)

	// config.yaml smart mode: claude + two codex instances on distinct models.
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	if err := os.MkdirAll(filepath.Join(home, ".cerberus"), 0o755); err != nil {
		t.Fatalf("MkdirAll(.cerberus) error = %v", err)
	}
	// The gpt-5.4 slot carries a review-only strategy whose prompt file is not
	// reachable from the generator cwd; generation must still succeed because
	// generators skip strategy/persona validation.
	configData := "version: 1\n" +
		"roster:\n" +
		"  smart:\n" +
		"    models:\n" +
		"      - provider: claude\n" +
		"        model: \"opus[1m]\"\n" +
		"        effort: medium\n" +
		"      - provider: codex\n" +
		"        model: gpt-5.5\n" +
		"        effort: medium\n" +
		"      - provider: codex\n" +
		"        model: gpt-5.4\n" +
		"        effort: high\n" +
		"        strategy: verification-first\n"
	if err := os.WriteFile(filepath.Join(home, ".cerberus", "config.yaml"), []byte(configData), 0o644); err != nil {
		t.Fatalf("WriteFile(config) error = %v", err)
	}

	binDir := t.TempDir()
	for _, provider := range []string{"claude", "codex"} {
		writeInstanceRecordingMock(t, binDir, provider)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	recordDir := t.TempDir()
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", recordDir)

	promptFile := filepath.Join(t.TempDir(), "prompt.md")
	if err := os.WriteFile(promptFile, []byte("fixture prompt"), 0o644); err != nil {
		t.Fatalf("WriteFile(prompt) error = %v", err)
	}
	outputDir := filepath.Join(t.TempDir(), "created-output")

	var stdout, stderr bytes.Buffer
	code := run([]string{"generate", outputDir, "--type", "create-spec", "--mode", "smart", "--prompt-file", promptFile, "--skip-interview"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run(generate) exit code = %d, want 0; stderr: %s", code, stderr.String())
	}

	for _, label := range []string{"claude", "codex", "codex-2"} {
		path := filepath.Join(outputDir, label, "draft.md")
		if got, err := os.ReadFile(path); err != nil || len(got) == 0 {
			t.Fatalf("draft %s read = %q, %v; want non-empty", label, got, err)
		}
		if !strings.Contains(stdout.String(), path) {
			t.Fatalf("run(generate) stdout = %q, want printed draft path %q", stdout.String(), path)
		}
	}
	// gemini must not appear — it was replaced by the second codex instance.
	if _, err := os.Stat(filepath.Join(outputDir, "gemini")); !os.IsNotExist(err) {
		t.Fatalf("gemini output dir stat err = %v, want not exist", err)
	}
	// Reviewer instance IDs stay in <provider>#<n> form; record files are keyed
	// by CERBERUS_MOCK_INSTANCE_ID, while output dirs use the label.
	assertGenerateRecordedModel(t, recordDir, "codex#1", "gpt-5.5")
	assertGenerateRecordedModel(t, recordDir, "codex#2", "gpt-5.4")
}

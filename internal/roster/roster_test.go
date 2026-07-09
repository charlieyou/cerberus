package roster

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProjectConfigBeatsUserConfig(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	withFakeCLIs(t, dir)
	userConfig := filepath.Join(dir, "xdg")
	t.Setenv("XDG_CONFIG_HOME", userConfig)
	writeConfigFile(t, filepath.Join(userConfig, "cerberus", "config.yaml"), "user-model")
	writeConfigFile(t, filepath.Join(dir, ".cerberus", "config.yaml"), "project-model")

	file, err := LoadConfig("")
	if err != nil {
		t.Fatalf("LoadConfig() error = %v", err)
	}
	if got := file.Roster["smart"].Models[0].Model; got != "project-model" {
		t.Fatalf("loaded model = %q, want project-model", got)
	}
}

func TestOldRostersYAMLIsIgnored(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	withFakeCLIs(t, dir)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(dir, "xdg"))
	t.Setenv("HOME", filepath.Join(dir, "home"))
	writeFile(t, filepath.Join(dir, ".cerberus", "rosters.yaml"), "version: 1\nrosters: {}\n")

	file, err := LoadConfig("")
	if err != nil {
		t.Fatalf("LoadConfig() error = %v", err)
	}
	if file != nil {
		t.Fatalf("LoadConfig() = %#v, want nil when only rosters.yaml exists", file)
	}
}

func TestBuiltInPanelsResolveByMode(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	withFakeCLIs(t, dir)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(dir, "xdg"))
	t.Setenv("HOME", filepath.Join(dir, "home"))

	slots, err := Resolve(nil, "max")
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	assertInstanceIDs(t, slots, []string{"claude#1", "codex#1", "gemini#1"})
	assertSlotModels(t, slots, []string{"fable", "gpt-5.6-sol", "gemini-3.1-pro-preview"})
	assertSlotEfforts(t, slots, []string{"high", "high", "high"})
}

func TestCustomModeSelectsItsOwnModelsAndEffort(t *testing.T) {
	dir := t.TempDir()
	withFakeCLIs(t, dir)
	path := filepath.Join(dir, "config.yaml")
	writeFile(t, path, `version: 1
defaults:
  mode: deep-review
roster:
  quick:
    models:
      - provider: codex
        model: quick-model
        effort: low
  deep-review:
    models:
      - provider: codex
        model: deep-model
        effort: high
      - provider: claude
        model: opus
        effort: medium
`)
	file, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig() error = %v", err)
	}

	defaultSlots, err := Resolve(file, "")
	if err != nil {
		t.Fatalf("Resolve(default) error = %v", err)
	}
	assertSlotModels(t, defaultSlots, []string{"deep-model", "opus"})
	assertSlotEfforts(t, defaultSlots, []string{"high", "medium"})

	quickSlots, err := Resolve(file, "quick")
	if err != nil {
		t.Fatalf("Resolve(quick) error = %v", err)
	}
	assertSlotModels(t, quickSlots, []string{"quick-model"})
	assertSlotEfforts(t, quickSlots, []string{"low"})
}

func TestUnknownModeRejects(t *testing.T) {
	dir := t.TempDir()
	withFakeCLIs(t, dir)
	path := filepath.Join(dir, "config.yaml")
	writeConfigFile(t, path, "model")
	file, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig() error = %v", err)
	}

	_, err = Resolve(file, "not-defined")
	if err == nil || !strings.Contains(err.Error(), `mode "not-defined"`) || !strings.Contains(err.Error(), "mode is not defined under roster") {
		t.Fatalf("Resolve() error = %v, want undefined mode error", err)
	}
}

func TestLegacyTopLevelRostersRejects(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	writeFile(t, path, `version: 1
rosters:
  default:
    reviewers:
      - provider: codex
        model: gpt
`)

	_, err := LoadConfig(path)
	if err == nil || !strings.Contains(err.Error(), `unknown top-level key "rosters"`) {
		t.Fatalf("LoadConfig() error = %v, want strict legacy schema rejection", err)
	}
}

func TestEffortIsRequired(t *testing.T) {
	dir := t.TempDir()
	withFakeCLIs(t, dir)
	path := filepath.Join(dir, "config.yaml")
	writeFile(t, path, `version: 1
roster:
  smart:
    models:
      - provider: codex
        model: gpt
`)
	_, err := LoadConfig(path)
	if err == nil || !strings.Contains(err.Error(), "effort must be low, medium, high, xhigh, or max") {
		t.Fatalf("LoadConfig() error = %v, want required effort error", err)
	}
}

func TestLoadConfigValidatesModelsInEveryMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	writeFile(t, path, `version: 1
defaults:
  mode: smart
roster:
  smart:
    models:
      - provider: codex
        model: valid-model
        effort: medium
  unused:
    models:
      - provider: codex
        model: broken-model
`)

	_, err := LoadConfig(path)
	if err == nil {
		t.Fatal("LoadConfig() error = nil, want invalid unused mode rejection")
	}
	for _, want := range []string{`mode "unused"`, "model 1", "effort must be low, medium, high, xhigh, or max"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("LoadConfig() error = %q, want %q", err, want)
		}
	}
}

func TestLoadConfigAcceptsExtendedEfforts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	writeFile(t, path, `version: 1
roster:
  smart:
    models:
      - provider: codex
        model: gpt
        effort: xhigh
      - provider: claude
        model: opus
        effort: max
`)

	if _, err := LoadConfig(path); err != nil {
		t.Fatalf("LoadConfig() error = %v, want xhigh and max efforts accepted", err)
	}
}

func TestLoadConfigRejectsWhitespaceOnlyModel(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	writeFile(t, path, `version: 1
roster:
  smart:
    models:
      - provider: codex
        model: "   "
        effort: medium
`)

	_, err := LoadConfig(path)
	if err == nil || !strings.Contains(err.Error(), "model is required") {
		t.Fatalf("LoadConfig() error = %v, want required model error", err)
	}
}

func TestLoadConfigRejectsMultipleYAMLDocuments(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	writeFile(t, path, `version: 1
roster:
  smart:
    models:
      - provider: codex
        model: valid-model
        effort: medium
---
bogus: true
`)

	_, err := LoadConfig(path)
	if err == nil || !strings.Contains(err.Error(), "multiple YAML documents are not allowed") {
		t.Fatalf("LoadConfig() error = %v, want multiple-document rejection", err)
	}
}

func TestPersonaPathResolvedRelativeToConfigFile(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	withFakeCLIs(t, dir)
	writeFile(t, filepath.Join(dir, "config", "personas", "security.md"), "security persona\n")
	path := filepath.Join(dir, "config", "config.yaml")
	writeFile(t, path, `version: 1
roster:
  smart:
    models:
      - provider: codex
        model: gpt
        effort: high
        persona: ./personas/security.md
`)
	file, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig() error = %v", err)
	}
	slots, err := Resolve(file, "smart")
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	want, _ := filepath.Abs(filepath.Join(dir, "config", "personas", "security.md"))
	if slots[0].PersonaPath != want {
		t.Fatalf("PersonaPath = %q, want %q", slots[0].PersonaPath, want)
	}
}

func TestUnknownModelKeyRejectsWithModeAndIndex(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	writeFile(t, path, `version: 1
roster:
  custom:
    models:
      - provider: codex
        model: gpt
        effort: medium
        unexpected: true
`)

	_, err := LoadConfig(path)
	if err == nil {
		t.Fatal("LoadConfig() error = nil, want unknown key error")
	}
	for _, want := range []string{path, `mode "custom"`, "model 1", "unexpected"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error %q does not contain %q", err, want)
		}
	}
}

func TestDebateMinimumStillAppliesToSelectedMode(t *testing.T) {
	err := EnforceDebateMinimum([]RosterSlot{{Provider: "codex", Model: "gpt", Effort: "high"}}, true)
	if err == nil {
		t.Fatal("EnforceDebateMinimum() error = nil")
	}
	var preflight PreflightError
	if !errors.As(err, &preflight) || preflight.ExitCode() != 6 {
		t.Fatalf("error = %#v, want exit-code 6 PreflightError", err)
	}
}

func loadConfig(t *testing.T, dir string, specs []string) *Config {
	t.Helper()
	var body strings.Builder
	body.WriteString("version: 1\nroster:\n  smart:\n    models:\n")
	for _, spec := range specs {
		parts := strings.Split(spec, ":")
		body.WriteString("      - provider: " + parts[0] + "\n")
		body.WriteString("        model: " + parts[1] + "\n")
		body.WriteString("        effort: " + parts[2] + "\n")
		if len(parts) > 3 && parts[3] != "" {
			body.WriteString("        strategy: " + parts[3] + "\n")
		}
	}
	path := filepath.Join(dir, "config.yaml")
	writeFile(t, path, body.String())
	file, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig() error = %v", err)
	}
	return file
}

func writeConfigFile(t *testing.T, path, model string) {
	t.Helper()
	writeFile(t, path, "version: 1\ndefaults:\n  mode: smart\nroster:\n  smart:\n    models:\n      - provider: codex\n        model: "+model+"\n        effort: medium\n")
}

func writeStrategy(t *testing.T, dir, name string) {
	t.Helper()
	writeFile(t, filepath.Join(dir, "prompts", "strategies", name+".md"), "# "+name+"\n")
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
}

func chdir(t *testing.T, dir string) {
	t.Helper()
	original, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd() error = %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("Chdir() error = %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(original) })
}

func withFakeCLIs(t *testing.T, dir string) {
	t.Helper()
	withFakeCLIsForProviders(t, dir, "claude", "codex", "gemini")
}

func assertInstanceIDs(t *testing.T, slots []RosterSlot, want []string) {
	t.Helper()
	if len(slots) != len(want) {
		t.Fatalf("len(slots) = %d, want %d", len(slots), len(want))
	}
	for i := range slots {
		if slots[i].InstanceID != want[i] {
			t.Fatalf("slot %d InstanceID = %q, want %q", i, slots[i].InstanceID, want[i])
		}
	}
}

func assertSlotModels(t *testing.T, slots []RosterSlot, want []string) {
	t.Helper()
	for i := range slots {
		if slots[i].Model != want[i] {
			t.Fatalf("slot %d Model = %q, want %q", i, slots[i].Model, want[i])
		}
	}
}

func assertSlotEfforts(t *testing.T, slots []RosterSlot, want []string) {
	t.Helper()
	for i := range slots {
		if slots[i].Effort != want[i] {
			t.Fatalf("slot %d Effort = %q, want %q", i, slots[i].Effort, want[i])
		}
	}
}

func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	original := os.Stderr
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe() error = %v", err)
	}
	os.Stderr = writer
	defer func() { os.Stderr = original }()
	fn()
	_ = writer.Close()
	data, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("read stderr capture: %v", err)
	}
	_ = reader.Close()
	return string(data)
}

package roster

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProjectRostersFileBeatsUserFile(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	userConfig := filepath.Join(dir, "xdg")
	t.Setenv("XDG_CONFIG_HOME", userConfig)
	writeRosterFile(t, filepath.Join(userConfig, "cerberus", "rosters.yaml"), "user-model")
	writeRosterFile(t, filepath.Join(dir, ".cerberus", "rosters.yaml"), "project-model")

	file, err := LoadRosters("")
	if err != nil {
		t.Fatalf("LoadRosters() error = %v", err)
	}
	if got := file.Rosters["default"].Reviewers[0].Model; got != "project-model" {
		t.Fatalf("loaded model = %q, want project-model", got)
	}
}

func TestBuiltInDefaultPanelWhenNoFile(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	withFakeCLIs(t, dir)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(dir, "xdg"))
	t.Setenv("HOME", filepath.Join(dir, "home"))

	file, err := LoadRosters("")
	if err != nil {
		t.Fatalf("LoadRosters() error = %v", err)
	}
	if file != nil {
		t.Fatalf("LoadRosters() = %v, want nil without file", file)
	}
	slots, err := Resolve(file, "", nil, "")
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	assertInstanceIDs(t, slots, []string{"claude#1", "codex#1", "gemini#1"})
	assertSlotModels(t, slots, []string{"opus[1m]", "gpt-5.5", "gemini-3.1-pro-preview"})
}

func TestBuiltInDefaultPanelDebateRejectsZeroAvailableReviewersWithDebateMinimum(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	t.Setenv("PATH", filepath.Join(dir, "empty-bin"))

	_, err := ResolveWithOptions(nil, ResolveOptions{Debate: true})
	if err == nil {
		t.Fatal("ResolveWithOptions() error = nil, want debate minimum error")
	}
	var preflight PreflightError
	if !errors.As(err, &preflight) {
		t.Fatalf("ResolveWithOptions() error type = %T, want PreflightError", err)
	}
	if preflight.ExitCode() != 6 {
		t.Fatalf("ExitCode() = %d, want 6", preflight.ExitCode())
	}
	if preflight.TelemetryReason() != DebateMinimumReason {
		t.Fatalf("TelemetryReason() = %q, want %q", preflight.TelemetryReason(), DebateMinimumReason)
	}
	if !strings.Contains(err.Error(), "--debate requires at least 2 reviewers in the resolved roster (got 0)") {
		t.Fatalf("error = %q, want debate minimum zero-reviewer message", err.Error())
	}
}

func TestNamedRosterWithoutFileErrors(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	withFakeCLIs(t, dir)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(dir, "xdg"))
	t.Setenv("HOME", filepath.Join(dir, "home"))

	file, err := LoadRosters("")
	if err != nil {
		t.Fatalf("LoadRosters() error = %v", err)
	}
	if file != nil {
		t.Fatalf("LoadRosters() = %v, want nil without file", file)
	}

	_, err = Resolve(file, "custom", nil, "")
	if err == nil {
		t.Fatal("Resolve() error = nil, want missing roster file error")
	}
	message := err.Error()
	for _, want := range []string{"<built-in>", "custom", "requires a rosters.yaml file"} {
		if !strings.Contains(message, want) {
			t.Fatalf("error %q does not contain %q", message, want)
		}
	}
}

func TestExistingFileWithoutDefaultRosterErrors(t *testing.T) {
	dir := t.TempDir()
	withFakeCLIs(t, dir)
	path := filepath.Join(dir, "rosters.yaml")
	writeFile(t, path, `version: 1
rosters:
  custom:
    reviewers:
      - provider: codex
        model: gpt-5.5
`)
	file, err := LoadRosters(path)
	if err != nil {
		t.Fatalf("LoadRosters() error = %v", err)
	}

	_, err = Resolve(file, "", nil, "")
	if err == nil {
		t.Fatal("Resolve() error = nil, want missing default error")
	}
	message := err.Error()
	for _, want := range []string{path, "default", "pass --roster <name>", "remove rosters.yaml"} {
		if !strings.Contains(message, want) {
			t.Fatalf("error %q does not contain %q", message, want)
		}
	}
}

func TestExplicitZeroMaxRoundsRejects(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rosters.yaml")
	writeFile(t, path, `version: 1
defaults:
  max_rounds: 0
rosters:
  default:
    reviewers:
      - provider: codex
        model: gpt-5.5
`)
	file, err := LoadRosters(path)
	if err != nil {
		t.Fatalf("LoadRosters() error = %v", err)
	}

	_, err = Resolve(file, "default", nil, "")
	if err == nil {
		t.Fatal("Resolve() error = nil, want max_rounds error")
	}
	message := err.Error()
	for _, want := range []string{path, "default", "slot 0", "max_rounds must be positive"} {
		if !strings.Contains(message, want) {
			t.Fatalf("error %q does not contain %q", message, want)
		}
	}
}

func TestCLIReviewerAppends(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	withFakeCLIs(t, dir)
	writeStrategy(t, dir, "verification-first")
	file := loadDefaultRoster(t, dir, []string{"codex:gpt-5.4:"})

	slots, err := Resolve(file, "default", []string{"codex:gpt-5.5:verification-first"}, "")
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	if len(slots) != 2 {
		t.Fatalf("len(slots) = %d, want 2", len(slots))
	}
	if got := slots[1].Model + ":" + slots[1].Strategy; got != "gpt-5.5:verification-first" {
		t.Fatalf("appended slot = %q, want gpt-5.5:verification-first", got)
	}
	assertInstanceIDs(t, slots, []string{"codex#1", "codex#2"})
}

func TestPersonaPathResolvedRelativeToRosterFile(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	withFakeCLIs(t, dir)
	writeStrategy(t, dir, "verification-first")

	rosterDir := "config"
	writeFile(t, filepath.Join(rosterDir, "personas", "security.md"), "security persona\n")
	path := filepath.Join(rosterDir, "rosters.yaml")
	writeFile(t, path, `version: 1
rosters:
  default:
    reviewers:
      - provider: codex
        model: gpt-5.5
        persona: ./personas/security.md
`)
	file, err := LoadRosters(path)
	if err != nil {
		t.Fatalf("LoadRosters() error = %v", err)
	}

	slots, err := Resolve(file, "default", nil, "")
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	want, err := filepath.Abs(filepath.Join(rosterDir, "personas", "security.md"))
	if err != nil {
		t.Fatalf("Abs(persona path) error = %v", err)
	}
	if got := slots[0].PersonaPath; got != want {
		t.Fatalf("PersonaPath = %q, want %q", got, want)
	}
}

func TestReplaceSlotReplacesReviewer(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)
	withFakeCLIs(t, dir)
	writeStrategy(t, dir, "verification-first")
	writeStrategy(t, dir, "falsification-first")
	writeStrategy(t, dir, "decompose")
	file := loadDefaultRoster(t, dir, []string{
		"codex:gpt-5.5:verification-first",
		"codex:gpt-5.5:falsification-first",
	})

	slots, err := Resolve(file, "default", []string{"codex:gpt-5.5:decompose"}, "codex#2")
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	if got := slots[1].Strategy; got != "decompose" {
		t.Fatalf("replaced strategy = %q, want decompose", got)
	}
	assertInstanceIDs(t, slots, []string{"codex#1", "codex#2"})
}

func TestDuplicateTriplesWarnAndGetDistinctInstanceIDs(t *testing.T) {
	dir := t.TempDir()
	withFakeCLIs(t, dir)
	file := loadDefaultRoster(t, dir, []string{
		"codex:gpt-5.5:",
		"codex:gpt-5.5:",
	})

	stderr := captureStderr(t, func() {
		slots, err := Resolve(file, "default", nil, "")
		if err != nil {
			t.Fatalf("Resolve() error = %v", err)
		}
		assertInstanceIDs(t, slots, []string{"codex#1", "codex#2"})
	})
	if !strings.Contains(stderr, "duplicate reviewer slot tuple") {
		t.Fatalf("stderr = %q, want duplicate warning", stderr)
	}
}

func TestEnforceDebateMinimumRejectsOneReviewer(t *testing.T) {
	err := EnforceDebateMinimum([]RosterSlot{{Provider: "codex", Model: "gpt-5.5"}}, true)
	if err == nil {
		t.Fatal("EnforceDebateMinimum() error = nil, want debate minimum error")
	}
	var preflight PreflightError
	if !errors.As(err, &preflight) {
		t.Fatalf("EnforceDebateMinimum() error type = %T, want PreflightError", err)
	}
	if preflight.ExitCode() != 6 {
		t.Fatalf("ExitCode() = %d, want 6", preflight.ExitCode())
	}
	if preflight.TelemetryReason() != DebateMinimumReason {
		t.Fatalf("TelemetryReason() = %q, want %q", preflight.TelemetryReason(), DebateMinimumReason)
	}
	if !strings.Contains(err.Error(), "--debate requires at least 2 reviewers in the resolved roster (got 1)") {
		t.Fatalf("error = %q, want resolved roster count", err.Error())
	}
}

func TestEnforceDebateMinimumRejectsZeroReviewers(t *testing.T) {
	err := EnforceDebateMinimum(nil, true)
	if err == nil {
		t.Fatal("EnforceDebateMinimum() error = nil, want debate minimum error")
	}
	if !strings.Contains(err.Error(), "got 0") {
		t.Fatalf("error = %q, want zero count", err.Error())
	}
}

func TestEnforceDebateMinimumAcceptsTwoReviewers(t *testing.T) {
	err := EnforceDebateMinimum([]RosterSlot{
		{Provider: "codex", Model: "gpt-5.5"},
		{Provider: "claude", Model: "opus"},
	}, true)
	if err != nil {
		t.Fatalf("EnforceDebateMinimum() error = %v, want nil", err)
	}
}

func TestEnforceDebateMinimumAllowsOneReviewerWithoutDebate(t *testing.T) {
	err := EnforceDebateMinimum([]RosterSlot{{Provider: "codex", Model: "gpt-5.5"}}, false)
	if err != nil {
		t.Fatalf("EnforceDebateMinimum() error = %v, want nil", err)
	}
}

func TestUnknownYAMLKeyAtSlotRejectsWithPathAndSlotIndex(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rosters.yaml")
	writeFile(t, path, `version: 1
rosters:
  default:
    reviewers:
      - provider: codex
        model: gpt-5.5
        unexpected: true
`)

	_, err := LoadRosters(path)
	if err == nil {
		t.Fatal("LoadRosters() error = nil, want unknown key error")
	}
	message := err.Error()
	for _, want := range []string{path, `roster "default"`, "slot 1", "unexpected"} {
		if !strings.Contains(message, want) {
			t.Fatalf("error %q does not contain %q", message, want)
		}
	}
}

func TestInstanceIDAssignmentWalksListByProvider(t *testing.T) {
	dir := t.TempDir()
	withFakeCLIs(t, dir)
	file := loadDefaultRoster(t, dir, []string{
		"gemini:gemini-3.1-pro:",
		"codex:gpt-5.5:",
		"gemini:gemini-3.1-flash:",
		"claude:opus:",
		"codex:gpt-5.4:",
	})

	slots, err := Resolve(file, "default", nil, "")
	if err != nil {
		t.Fatalf("Resolve() error = %v", err)
	}
	assertInstanceIDs(t, slots, []string{"gemini#1", "codex#1", "gemini#2", "claude#1", "codex#2"})
}

func TestResolveWithOptionsSkipStrategyPersonaForGenerators(t *testing.T) {
	dir := t.TempDir()
	chdir(t, dir)        // cwd has no prompts/strategies directory
	withFakeCLIs(t, dir) // claude/codex available on PATH
	file := loadDefaultRoster(t, dir, []string{
		"claude:opus:",
		"codex:gpt-5.5:",
		"codex:gpt-5.4:verification-first", // strategy file intentionally absent
	})

	// Review resolution validates the strategy file and fails when it is absent.
	if _, err := Resolve(file, "", nil, ""); err == nil {
		t.Fatal("Resolve() error = nil, want missing strategy-file validation error")
	}

	// Generator resolution skips review-only strategy/persona validation.
	slots, err := ResolveWithOptions(file, ResolveOptions{SkipStrategyPersona: true})
	if err != nil {
		t.Fatalf("ResolveWithOptions(SkipStrategyPersona) error = %v", err)
	}
	assertInstanceIDs(t, slots, []string{"claude#1", "codex#1", "codex#2"})
}

func loadDefaultRoster(t *testing.T, dir string, specs []string) *RostersFile {
	t.Helper()
	var yaml strings.Builder
	yaml.WriteString("version: 1\nrosters:\n  default:\n    reviewers:\n")
	for _, spec := range specs {
		parts := strings.Split(spec, ":")
		yaml.WriteString("      - provider: " + parts[0] + "\n")
		yaml.WriteString("        model: " + parts[1] + "\n")
		if len(parts) > 2 && parts[2] != "" {
			yaml.WriteString("        strategy: " + parts[2] + "\n")
		}
	}
	path := filepath.Join(dir, "rosters.yaml")
	writeFile(t, path, yaml.String())
	file, err := LoadRosters(path)
	if err != nil {
		t.Fatalf("LoadRosters() error = %v", err)
	}
	return file
}

func writeRosterFile(t *testing.T, path, model string) {
	t.Helper()
	writeFile(t, path, "version: 1\nrosters:\n  default:\n    reviewers:\n      - provider: codex\n        model: "+model+"\n")
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
	t.Cleanup(func() {
		if err := os.Chdir(original); err != nil {
			t.Fatalf("restore Chdir() error = %v", err)
		}
	})
}

func withFakeCLIs(t *testing.T, dir string) {
	t.Helper()
	bin := filepath.Join(dir, "bin")
	for _, name := range []string{"claude", "codex", "gemini"} {
		writeFile(t, filepath.Join(bin, name), "#!/bin/sh\nexit 0\n")
		if err := os.Chmod(filepath.Join(bin, name), 0o755); err != nil {
			t.Fatalf("Chmod() error = %v", err)
		}
	}
	t.Setenv("PATH", bin)
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
	if len(slots) != len(want) {
		t.Fatalf("len(slots) = %d, want %d", len(slots), len(want))
	}
	for i := range slots {
		if slots[i].Model != want[i] {
			t.Fatalf("slot %d Model = %q, want %q", i, slots[i].Model, want[i])
		}
	}
}

func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	original := os.Stderr
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatalf("Pipe() error = %v", err)
	}
	os.Stderr = write
	defer func() {
		os.Stderr = original
	}()

	fn()
	if err := write.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(read); err != nil {
		t.Fatalf("ReadFrom() error = %v", err)
	}
	return buf.String()
}

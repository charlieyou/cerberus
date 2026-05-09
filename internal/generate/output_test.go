package generate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestOutputWriteSuccessWritesDraftRawAndStats(t *testing.T) {
	outputDir := t.TempDir()
	raw := []byte(`{"usage":{"input_tokens":10,"output_tokens":4}}`)

	if err := WriteSuccess(outputDir, "codex", []byte("# draft\n"), raw); err != nil {
		t.Fatalf("WriteSuccess() error = %v", err)
	}
	cost := 0.012
	if err := WriteStats(outputDir, "codex", Stats{
		Tokens:         &TokenStats{Input: 10, Output: 4},
		CostUSD:        &cost,
		TimeToFinishMs: 25,
		ExitCode:       0,
		StartedAt:      time.Unix(1, 0).UTC(),
		EndedAt:        time.Unix(2, 0).UTC(),
	}); err != nil {
		t.Fatalf("WriteStats() error = %v", err)
	}

	assertFileContent(t, filepath.Join(outputDir, "codex", "draft.md"), "# draft\n")
	assertFileContent(t, filepath.Join(outputDir, "codex", "raw.json"), string(raw))
	stats := readStatsFile(t, filepath.Join(outputDir, "codex", "stats.json"))
	if stats.Tokens == nil || stats.Tokens.Input != 10 || stats.Tokens.Output != 4 {
		t.Fatalf("stats tokens = %#v, want input=10 output=4", stats.Tokens)
	}
	if stats.CostUSD == nil || *stats.CostUSD != cost {
		t.Fatalf("stats cost = %#v, want %v", stats.CostUSD, cost)
	}
	if stats.ExitCode != 0 {
		t.Fatalf("stats exit_code = %d, want 0", stats.ExitCode)
	}

	if err := WriteSuccess(outputDir, "codex", []byte("# replacement\n"), nil); err != nil {
		t.Fatalf("WriteSuccess() replacement error = %v", err)
	}
	assertFileContent(t, filepath.Join(outputDir, "codex", "draft.md"), "# replacement\n")
}

func TestOutputWriteSuccessOmitsRawJSONForMarkdown(t *testing.T) {
	outputDir := t.TempDir()

	if err := WriteSuccess(outputDir, "claude", []byte("# draft\n"), nil); err != nil {
		t.Fatalf("WriteSuccess() error = %v", err)
	}
	if _, err := os.Stat(filepath.Join(outputDir, "claude", "raw.json")); !os.IsNotExist(err) {
		t.Fatalf("raw.json stat err = %v, want not exist", err)
	}
}

func TestOutputWriteFailureWritesParentMarkerAndStats(t *testing.T) {
	outputDir := t.TempDir()

	if err := WriteFailure(outputDir, "gemini", 9, "boom"); err != nil {
		t.Fatalf("WriteFailure() error = %v", err)
	}
	if err := WriteStats(outputDir, "gemini", Stats{
		TimeToFinishMs: 30,
		ExitCode:       9,
		ErrorMessage:   "boom",
		StartedAt:      time.Unix(1, 0).UTC(),
		EndedAt:        time.Unix(2, 0).UTC(),
	}); err != nil {
		t.Fatalf("WriteStats() error = %v", err)
	}

	assertFileContent(t, filepath.Join(outputDir, "gemini.failed"), "boom")
	stats := readStatsFile(t, filepath.Join(outputDir, "gemini", "stats.json"))
	if stats.ExitCode != 9 {
		t.Fatalf("stats exit_code = %d, want 9", stats.ExitCode)
	}
	if !strings.Contains(stats.ErrorMessage, "boom") {
		t.Fatalf("stats error_message = %q, want boom", stats.ErrorMessage)
	}
}

func assertFileContent(t *testing.T, path, want string) {
	t.Helper()
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	if string(got) != want {
		t.Fatalf("%s = %q, want %q", path, got, want)
	}
}

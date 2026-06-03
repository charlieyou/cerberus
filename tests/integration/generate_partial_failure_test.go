package integration_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestGeneratePartialFailure(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)

	for _, generatorType := range []string{"create-spec", "create-plan"} {
		t.Run(generatorType, func(t *testing.T) {
			root := newGeneratePromptRoot(t, generatorType, "partial "+generatorType+" template")
			prompt := "write a " + generatorType + " draft"
			fixtureDir := keyedGenerateFixtureDir(t, repoRoot, generatorType, prompt, []string{"claude", "gemini"})

			outputDir := t.TempDir()
			recordDir := t.TempDir()
			args := []string{"generate", outputDir, "--type", generatorType, "--mode", "smart", "--prompt-file", writePromptFile(t, prompt)}
			cmd := exec.Command(binary, args...)
			cmd.Dir = t.TempDir()
			cmd.Env = append(os.Environ(),
				"CERBERUS_ROOT="+root,
				"CERBERUS_FIXTURE_DIR="+fixtureDir,
				"CERBERUS_MOCK_RECORD_DIR="+recordDir,
				"PATH="+integrationMockPath(t, repoRoot)+string(os.PathListSeparator)+os.Getenv("PATH"),
			)
			output, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("cerberus generate returned %v, want exit 0 for partial failure\n%s", err, output)
			}
			if !strings.Contains(string(output), "2 providers succeeded, 1 failed (codex.failed)") {
				t.Fatalf("stderr = %q, want partial failure summary", output)
			}

			for _, provider := range []string{"claude", "gemini"} {
				got, err := os.ReadFile(filepath.Join(outputDir, provider, "draft.md"))
				if err != nil {
					t.Fatalf("ReadFile(%s draft) error = %v", provider, err)
				}
				want, err := os.ReadFile(filepath.Join(repoRoot, "tests", "fixtures", "generate", provider+"-"+generatorType+".md"))
				if err != nil {
					t.Fatalf("ReadFile(%s fixture) error = %v", provider, err)
				}
				if string(got) != string(want) {
					t.Fatalf("%s draft = %q, want fixture %q", provider, got, want)
				}
				if stats := readGenerateStats(t, filepath.Join(outputDir, provider, "stats.json")); stats.ExitCode != 0 {
					t.Fatalf("%s exit_code = %d, want 0", provider, stats.ExitCode)
				}
			}
			if _, err := os.Stat(filepath.Join(outputDir, "codex", "draft.md")); !os.IsNotExist(err) {
				t.Fatalf("codex draft stat err = %v, want not exist", err)
			}
			if _, err := os.Stat(filepath.Join(outputDir, "codex.failed")); err != nil {
				t.Fatalf("codex.failed stat err = %v, want exist", err)
			}
			stats := readGenerateStats(t, filepath.Join(outputDir, "codex", "stats.json"))
			if stats.ExitCode == 0 || !strings.Contains(stats.ErrorMessage, "generator codex failed") {
				t.Fatalf("codex stats = %#v, want failure", stats)
			}
		})
	}
}

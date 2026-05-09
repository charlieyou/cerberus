package integration_test

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var generateProviders = []string{"claude", "codex", "gemini"}

type generateRun struct {
	outputDir string
	recordDir string
	stderr    string
}

type generateStats struct {
	ExitCode     int    `json:"exit_code"`
	ErrorMessage string `json:"error_message,omitempty"`
}

func buildIntegrationCerberus(t *testing.T, repoRoot string) string {
	t.Helper()
	binary := filepath.Join(t.TempDir(), "cerberus")
	build := exec.Command("go", "build", "-o", binary, "./cmd/cerberus")
	build.Dir = repoRoot
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build ./cmd/cerberus failed: %v\n%s", err, output)
	}
	return binary
}

func integrationRepoRoot(t *testing.T) string {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	return repoRoot
}

func newGeneratePromptRoot(t *testing.T, generatorType, templateBody string) string {
	t.Helper()
	root := t.TempDir()
	writeIntegrationFile(t, root, "config/gemini-readonly-policy.toml", "# policy\n")
	writeIntegrationFile(t, root, "prompts/interview-engine.md", "# Interview\n\nAsk only necessary questions.\n")
	writeGeneratorTemplates(t, root, generatorType, templateBody)
	return root
}

func writeGeneratorTemplates(t *testing.T, root, generatorType, body string) {
	t.Helper()
	for _, provider := range generateProviders {
		writeIntegrationFile(t, root, filepath.Join("prompts", "generators", generatorType, provider+".md"), body+" "+provider+"\n")
	}
}

func writeIntegrationFile(t *testing.T, root, rel, content string) {
	t.Helper()
	path := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll(%s) error = %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

func writePromptFile(t *testing.T, body string) string {
	t.Helper()
	promptFile := filepath.Join(t.TempDir(), "prompt.md")
	if err := os.WriteFile(promptFile, []byte(body), 0o644); err != nil {
		t.Fatalf("WriteFile(prompt) error = %v", err)
	}
	return promptFile
}

func runGenerateCommand(t *testing.T, repoRoot, binary, root string, args ...string) generateRun {
	t.Helper()
	outputDir := t.TempDir()
	recordDir := t.TempDir()
	fixtureDir := filepath.Join(repoRoot, "tests", "fixtures", "generate")
	fullArgs := append([]string{"generate", outputDir}, args...)
	cmd := exec.Command(binary, fullArgs...)
	cmd.Dir = t.TempDir()
	cmd.Env = append(os.Environ(),
		"CERBERUS_ROOT="+root,
		"CERBERUS_FIXTURE_DIR="+fixtureDir,
		"CERBERUS_MOCK_RECORD_DIR="+recordDir,
		"PATH="+filepath.Join(repoRoot, "tests", "mocks")+string(os.PathListSeparator)+os.Getenv("PATH"),
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("cerberus generate %q failed: %v\n%s", fullArgs, err, output)
	}
	return generateRun{outputDir: outputDir, recordDir: recordDir, stderr: string(output)}
}

func assertGenerateOutputs(t *testing.T, repoRoot, outputDir, generatorType string) {
	t.Helper()
	for _, provider := range generateProviders {
		got, err := os.ReadFile(filepath.Join(outputDir, provider, "draft.md"))
		if err != nil {
			t.Fatalf("ReadFile(%s draft) error = %v", provider, err)
		}
		want, err := os.ReadFile(filepath.Join(repoRoot, "tests", "fixtures", "generate", provider+"-"+generatorType+".md"))
		if err != nil {
			t.Fatalf("ReadFile(%s fixture) error = %v", provider, err)
		}
		if len(bytes.TrimSpace(got)) == 0 {
			t.Fatalf("%s draft is empty", provider)
		}
		if string(got) != string(want) {
			t.Fatalf("%s draft = %q, want fixture %q", provider, got, want)
		}
		stats := readGenerateStats(t, filepath.Join(outputDir, provider, "stats.json"))
		if stats.ExitCode != 0 {
			t.Fatalf("%s stats exit_code = %d, want 0", provider, stats.ExitCode)
		}
		if stats.ErrorMessage != "" {
			t.Fatalf("%s stats error_message = %q, want empty", provider, stats.ErrorMessage)
		}
		if _, err := os.Stat(filepath.Join(outputDir, provider+".failed")); !os.IsNotExist(err) {
			t.Fatalf("%s failed marker stat err = %v, want not exist", provider, err)
		}
	}
}

func readGenerateStats(t *testing.T, path string) generateStats {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	var stats generateStats
	if err := json.Unmarshal(data, &stats); err != nil {
		t.Fatalf("Unmarshal(%s) error = %v", path, err)
	}
	return stats
}

func assertRecordedSystemPromptContains(t *testing.T, recordDir, generatorType, marker string) {
	t.Helper()
	for _, provider := range generateProviders {
		data, err := os.ReadFile(filepath.Join(recordDir, provider+".args"))
		if err != nil {
			t.Fatalf("ReadFile(%s args) error = %v", provider, err)
		}
		for _, want := range []string{"Cerberus generator type: " + generatorType + ".", marker + " " + provider} {
			if !strings.Contains(string(data), want) {
				t.Fatalf("%s args = %q, want %q", provider, data, want)
			}
		}
	}
}

func assertGenerateStdin(t *testing.T, recordDir, want string) {
	t.Helper()
	for _, provider := range generateProviders {
		got, err := os.ReadFile(filepath.Join(recordDir, provider+".stdin"))
		if err != nil {
			t.Fatalf("ReadFile(%s stdin) error = %v", provider, err)
		}
		if string(got) != want {
			t.Fatalf("%s stdin length = %d, want %d", provider, len(got), len(want))
		}
	}
}

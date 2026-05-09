package integration_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestGenerateWrapperFallsBackFromInvalidRoot(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	pluginRoot := t.TempDir()
	realPluginRoot := realPath(t, pluginRoot)
	installGenerateWrapper(t, repoRoot, pluginRoot)
	writeIntegrationFile(t, pluginRoot, "config/gemini-readonly-policy.toml", "# policy\n")
	writeIntegrationFile(t, pluginRoot, "prompts/interview-engine.md", "# Interview\n\nAsk only necessary questions.\n")
	writeGeneratorTemplates(t, pluginRoot, "create-spec", "wrapper create-spec template")

	promptFile := writePromptFile(t, "write a create-spec draft")
	outputDir := t.TempDir()
	recordDir := t.TempDir()
	badRoot := t.TempDir()
	fixtureDir := keyedGenerateFixtureDir(t, repoRoot, "create-spec", "write a create-spec draft", generateProviders)

	cmd := exec.Command(filepath.Join(pluginRoot, "bin", "generate"), outputDir, "--type", "create-spec", "--mode", "smart", "--prompt-file", promptFile)
	cmd.Dir = t.TempDir()
	cmd.Env = append(os.Environ(),
		"CERBERUS_ROOT="+badRoot,
		"CERBERUS_FIXTURE_DIR="+fixtureDir,
		"CERBERUS_MOCK_RECORD_DIR="+recordDir,
		"PATH="+filepath.Join(repoRoot, "tests", "mocks")+string(os.PathListSeparator)+os.Getenv("PATH"),
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bin/generate failed with invalid CERBERUS_ROOT: %v\n%s", err, output)
	}
	if got, want := string(output), "configured Cerberus root '"+badRoot+"' is missing backend files; using "+realPluginRoot; !strings.Contains(got, want) {
		t.Fatalf("bin/generate output = %q, want fallback warning %q", got, want)
	}
	assertGenerateOutputs(t, repoRoot, outputDir, "create-spec")
	assertRecordedSystemPromptContains(t, recordDir, "create-spec", "wrapper create-spec template")
}

func TestGenerateWrapperHelpUsesLegacyUsage(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	pluginRoot := t.TempDir()
	realPluginRoot := realPath(t, pluginRoot)
	installGenerateWrapper(t, repoRoot, pluginRoot)

	badRoot := t.TempDir()
	cmd := exec.Command(filepath.Join(pluginRoot, "bin", "generate"), "--help")
	cmd.Env = append(os.Environ(), "CERBERUS_ROOT="+badRoot)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bin/generate --help failed: %v\n%s", err, output)
	}
	got := string(output)
	for _, want := range []string{
		"configured Cerberus root '" + badRoot + "' is missing backend files; using " + realPluginRoot,
		"Usage: generate <output-dir> [options]",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("bin/generate --help output = %q, want %q", got, want)
		}
	}
}

func realPath(t *testing.T, path string) string {
	t.Helper()
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatalf("EvalSymlinks(%s) error = %v", path, err)
	}
	return real
}

func installGenerateWrapper(t *testing.T, repoRoot, pluginRoot string) {
	t.Helper()
	binDir := filepath.Join(pluginRoot, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("MkdirAll(%s) error = %v", binDir, err)
	}
	wrapper, err := os.ReadFile(filepath.Join(repoRoot, "bin", "generate"))
	if err != nil {
		t.Fatalf("ReadFile(bin/generate) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(binDir, "generate"), wrapper, 0o755); err != nil {
		t.Fatalf("WriteFile(wrapper) error = %v", err)
	}
	binary := buildIntegrationCerberus(t, repoRoot)
	cerberus, err := os.ReadFile(binary)
	if err != nil {
		t.Fatalf("ReadFile(cerberus binary) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(binDir, "cerberus"), cerberus, 0o755); err != nil {
		t.Fatalf("WriteFile(cerberus binary) error = %v", err)
	}
}

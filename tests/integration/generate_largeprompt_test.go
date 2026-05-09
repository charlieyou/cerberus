package integration_test

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestGenerateLargePrompt(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	root := newGeneratePromptRoot(t, "create-spec", "largeprompt create-spec template")
	prompt := string(bytes.Repeat([]byte("x"), 256*1024+1024))
	promptFile := writePromptFile(t, prompt)
	wantHash := fmt.Sprintf("%x", sha256.Sum256([]byte(prompt)))

	run := runGenerateCommand(t, repoRoot, binary, root, "--type", "create-spec", "--mode", "smart", "--prompt-file", promptFile)
	assertGenerateOutputs(t, repoRoot, run.outputDir, "create-spec")
	for _, provider := range generateProviders {
		gotHash := fmt.Sprintf("%x", sha256.Sum256(mustReadGenerateRecord(t, run.recordDir, provider+".stdin")))
		if gotHash != wantHash {
			t.Fatalf("%s stdin sha256 = %s, want %s", provider, gotHash, wantHash)
		}
		if bytes.Contains(mustReadGenerateRecord(t, run.recordDir, provider+".args"), []byte(prompt[:1024])) {
			t.Fatalf("%s argv contains the user prompt body; prompt must be sent via stdin", provider)
		}
	}
}

func mustReadGenerateRecord(t *testing.T, recordDir, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(recordDir, name))
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", name, err)
	}
	return data
}

package integration_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestMockSmoke(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	for _, provider := range generateProviders {
		t.Run(provider, func(t *testing.T) {
			binary := buildIntegrationMock(t, repoRoot, provider, t.TempDir())
			fixtureDir := filepath.Join(repoRoot, "tests", "fixtures", provider)
			prompt := []byte("mock smoke prompt for " + provider + "\n")
			instanceID := provider + "#1"
			key := mockFixtureKey(prompt, instanceID)
			fixturePath := filepath.Join(fixtureDir, key+".json")
			want, err := os.ReadFile(fixturePath)
			if err != nil {
				t.Fatalf("ReadFile(%s) error = %v", fixturePath, err)
			}

			run := exec.Command(binary)
			run.Env = append(os.Environ(),
				"CERBERUS_FIXTURE_DIR="+fixtureDir,
				"CERBERUS_MOCK_INSTANCE_ID="+instanceID,
			)
			run.Stdin = bytes.NewReader(prompt)
			got, err := run.Output()
			if err != nil {
				t.Fatalf("%s known fixture failed: %v", provider, err)
			}
			if !bytes.Equal(got, want) {
				t.Fatalf("%s stdout = %q, want fixture %q", provider, got, want)
			}

			missingPrompt := []byte("unknown prompt for " + provider + "\n")
			missingKey := mockFixtureKey(missingPrompt, instanceID)
			capturePath := filepath.Join(fixtureDir, missingKey+".json.prompt.txt")
			t.Cleanup(func() { _ = os.Remove(capturePath) })
			_ = os.Remove(capturePath)
			missing := exec.Command(binary)
			missing.Env = run.Env
			missing.Stdin = bytes.NewReader(missingPrompt)
			output, err := missing.CombinedOutput()
			exitErr, ok := err.(*exec.ExitError)
			if !ok || exitErr.ExitCode() != 2 {
				t.Fatalf("%s missing fixture err = %v, output = %q; want exit 2", provider, err, output)
			}
			wantStderr := "mock-" + provider + ": no fixture for prompt+instance; wrote " + capturePath
			if !strings.Contains(string(output), wantStderr) {
				t.Fatalf("%s missing stderr = %q, want %q", provider, output, wantStderr)
			}
			captured, err := os.ReadFile(capturePath)
			if err != nil {
				t.Fatalf("ReadFile(%s) error = %v", capturePath, err)
			}
			if !bytes.Equal(captured, missingPrompt) {
				t.Fatalf("%s captured prompt = %q, want %q", provider, captured, missingPrompt)
			}
		})
	}
}

func mockFixtureKey(prompt []byte, instanceID string) string {
	sum := sha256.Sum256(prompt)
	return hex.EncodeToString(sum[:8]) + ":" + instanceID
}

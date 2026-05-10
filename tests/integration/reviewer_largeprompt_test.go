package integration_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/charlieyou/cerberus/internal/reviewer"
)

func TestReviewerLargePromptStdinRoundTrip(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "config"), 0o755); err != nil {
		t.Fatalf("MkdirAll(config) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "config", "gemini-readonly-policy.toml"), []byte("# policy\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(policy) error = %v", err)
	}

	recordDir := t.TempDir()
	userPrompt := bytes.Repeat([]byte("x"), 256*1024+1024)
	wantHash := fmt.Sprintf("%x", sha256.Sum256(userPrompt))
	fixtureDir := reviewerLargePromptFixtureDir(t, userPrompt, wantHash)

	t.Setenv("CERBERUS_MOCK_RECORD_DIR", recordDir)
	t.Setenv("CERBERUS_FIXTURE_DIR", fixtureDir)
	t.Setenv("PATH", integrationMockPath(t, repoRoot)+string(os.PathListSeparator)+os.Getenv("PATH"))

	for _, provider := range generateProviders {
		t.Run(provider, func(t *testing.T) {
			response, err := (reviewer.Runner{Root: root, RunRoot: filepath.Join(t.TempDir(), "run"), Iteration: 1, Round: 1}).Spawn(context.Background(), reviewer.Request{
				ID:       provider + "#1",
				Provider: provider,
				Model:    "mock",
				System:   []byte("system"),
				User:     userPrompt,
			})
			if err != nil {
				if strings.Contains(err.Error(), "argument list too long") || strings.Contains(err.Error(), "E2BIG") || strings.Contains(err.Error(), syscall.E2BIG.Error()) {
					t.Fatalf("%s exec failed with E2BIG/argument list too long; prompt must be sent via stdin: %v", provider, err)
				}
				t.Fatalf("%s Spawn() error = %v", provider, err)
			}

			parsed, err := reviewer.Parse(response.Output)
			if err != nil {
				t.Fatalf("%s canonical reviewer output JSON parse error = %v; output = %s", provider, err, response.Output)
			}
			if parsed.Verdict != "PASS" {
				t.Fatalf("%s parsed verdict = %q, want PASS", provider, parsed.Verdict)
			}
			if !strings.Contains(parsed.Summary, wantHash) {
				t.Fatalf("%s canonical reviewer output summary = %q, want prompt sha256 %s", provider, parsed.Summary, wantHash)
			}

			stdinBytes, err := os.ReadFile(filepath.Join(recordDir, provider+".stdin"))
			if err != nil {
				t.Fatalf("%s stdin read failed: %v", provider, err)
			}
			gotHash := fmt.Sprintf("%x", sha256.Sum256(stdinBytes))
			if gotHash != wantHash {
				t.Fatalf("%s stdin sha256 = %s, want %s", provider, gotHash, wantHash)
			}
			stats := reviewerLargePromptStats(t, recordDir, provider)
			if stats.PromptSHA256 != wantHash {
				t.Fatalf("%s stats prompt_sha256 = %s, want %s", provider, stats.PromptSHA256, wantHash)
			}

			args, err := os.ReadFile(filepath.Join(recordDir, provider+".args"))
			if err != nil {
				t.Fatalf("%s argv read failed: %v", provider, err)
			}
			if bytes.Contains(args, userPrompt[:1024]) {
				t.Fatalf("%s argv contains the user prompt body; prompt must be sent via stdin", provider)
			}
		})
	}
}

func reviewerLargePromptFixtureDir(t *testing.T, userPrompt []byte, wantHash string) string {
	t.Helper()

	fixtureDir := t.TempDir()
	sum := sha256.Sum256(userPrompt)
	promptHash := hex.EncodeToString(sum[:8])
	for _, provider := range generateProviders {
		fixture := fmt.Sprintf(`{"findings":[],"verdict":"PASS","summary":"mock pass prompt_sha256=%s","overall_confidence":0.9,"strategy":"mock","round":1,"peer_responses_seen":[]}`+"\n", wantHash)
		path := filepath.Join(fixtureDir, promptHash+":"+provider+"#1.json")
		if err := os.WriteFile(path, []byte(fixture), 0o644); err != nil {
			t.Fatalf("WriteFile(%s) error = %v", path, err)
		}
	}
	return fixtureDir
}

type reviewerLargePromptMockStats struct {
	PromptSHA256 string `json:"prompt_sha256"`
}

func reviewerLargePromptStats(t *testing.T, recordDir, provider string) reviewerLargePromptMockStats {
	t.Helper()

	path := filepath.Join(recordDir, provider+".stats.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s stats read failed: %v", provider, err)
	}
	var stats reviewerLargePromptMockStats
	if err := json.Unmarshal(data, &stats); err != nil {
		t.Fatalf("%s stats JSON parse failed: %v", provider, err)
	}
	return stats
}

package generate

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunProviderCommandConstructionAndLargePromptStdin(t *testing.T) {
	root := t.TempDir()
	writeGeneratorPolicy(t, root)
	binDir := t.TempDir()
	recordDir := t.TempDir()
	for _, provider := range []string{"claude", "codex", "gemini"} {
		writeRecordingProvider(t, binDir, provider)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", recordDir)

	userPrompt := strings.Repeat("x", 256*1024+17)
	wantHash := sha256.Sum256([]byte(userPrompt))

	for _, provider := range []string{"claude", "codex", "gemini"} {
		t.Run(provider, func(t *testing.T) {
			stdout, stderr, err := runProvider(context.Background(), root, provider, "model-name", provider, "system prompt", userPrompt)
			if err != nil {
				t.Fatalf("runProvider() error = %v; stderr=%q", err, stderr)
			}
			if string(stdout) != "draft from "+provider+"\n" {
				t.Fatalf("stdout = %q, want provider draft", stdout)
			}

			args := readGeneratorRecord(t, recordDir, provider+".args")
			if strings.Contains(args, userPrompt[:1024]) {
				t.Fatalf("argv contains user prompt prefix")
			}
			if !strings.Contains(args, "system prompt\n") {
				t.Fatalf("%s args = %q, want system prompt in argv", provider, args)
			}
			if provider == "claude" {
				if !strings.Contains(args, "--append-system-prompt\nsystem prompt\n") {
					t.Fatalf("claude args = %q, want system prompt flag", args)
				}
				if !strings.Contains(args, "--print\n--output-format\njson\n") {
					t.Fatalf("claude args = %q, want print json flags", args)
				}
				if !strings.Contains(args, "--model\nmodel-name\n") {
					t.Fatalf("claude args = %q, want model flag honoring configured model", args)
				}
			}
			if provider == "codex" && !strings.Contains(args, "exec\n--json\n--model\nmodel-name\n") {
				t.Fatalf("codex args = %q, want exec json and model flags", args)
			}
			if provider == "gemini" {
				wantPolicy := filepath.Join(root, "config", "gemini-readonly-policy.toml")
				if !strings.Contains(args, "--output-format\njson\n--model\nmodel-name\n") {
					t.Fatalf("gemini args = %q, want JSON output-format and model flags", args)
				}
				if !strings.Contains(args, "--prompt\nsystem prompt\n") {
					t.Fatalf("gemini args = %q, want prompt flag", args)
				}
				if !strings.Contains(args, "use only the exact function names `glob`, `grep_search`, or `read_file`") {
					t.Fatalf("gemini args = %q, want tool-name directive", args)
				}
				for _, unsupported := range []string{"list_directory", "read_many_files"} {
					if strings.Contains(args, unsupported) {
						t.Fatalf("gemini args = %q, must not advertise unsupported tool %q", args, unsupported)
					}
				}
				if !strings.Contains(args, "--policy\n"+wantPolicy+"\n") {
					t.Fatalf("gemini args = %q, want policy file %s", args, wantPolicy)
				}
			}

			stdin := []byte(readGeneratorRecord(t, recordDir, provider+".stdin"))
			gotHash := sha256.Sum256(stdin)
			if gotHash != wantHash {
				t.Fatalf("stdin sha256 = %x, want %x", gotHash, wantHash)
			}
		})
	}
}

func TestRunProviderReturnsStdoutStderrAndError(t *testing.T) {
	root := t.TempDir()
	writeGeneratorPolicy(t, root)
	binDir := t.TempDir()
	recordDir := t.TempDir()
	writeFailingProvider(t, binDir, "codex")
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", recordDir)

	stdout, stderr, err := runProvider(context.Background(), root, "codex", "model-name", "codex", "system", "user")
	if err == nil {
		t.Fatal("runProvider() error = nil, want failure")
	}
	if string(stdout) != "partial stdout\n" {
		t.Fatalf("stdout = %q, want partial stdout", stdout)
	}
	if string(stderr) != "failure stderr\n" {
		t.Fatalf("stderr = %q, want failure stderr", stderr)
	}
	if !strings.Contains(err.Error(), "generator codex failed") {
		t.Fatalf("error = %q, want generator failure context", err)
	}
}

func writeRecordingProvider(t *testing.T, dir, provider string) {
	t.Helper()
	path := filepath.Join(dir, provider)
	body := "#!/bin/sh\nset -eu\ncat > \"$CERBERUS_MOCK_RECORD_DIR/" + provider + ".stdin\"\nprintf '%s\\n' \"$@\" > \"$CERBERUS_MOCK_RECORD_DIR/" + provider + ".args\"\nprintf 'draft from " + provider + "\\n'\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

func writeFailingProvider(t *testing.T, dir, provider string) {
	t.Helper()
	path := filepath.Join(dir, provider)
	body := "#!/bin/sh\nset -eu\ncat > \"$CERBERUS_MOCK_RECORD_DIR/" + provider + ".stdin\"\nprintf 'partial stdout\\n'\nprintf 'failure stderr\\n' >&2\nexit 9\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

func writeGeneratorPolicy(t *testing.T, root string) {
	t.Helper()
	path := filepath.Join(root, "config", "gemini-readonly-policy.toml")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll(policy dir) error = %v", err)
	}
	if err := os.WriteFile(path, []byte("# policy\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(policy) error = %v", err)
	}
}

func readGeneratorRecord(t *testing.T, dir, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", name, err)
	}
	return string(data)
}

func TestRunProviderRejectsUnsupportedProvider(t *testing.T) {
	_, _, err := runProvider(context.Background(), t.TempDir(), "unknown", "model", "unknown", "system", "user")
	if err == nil {
		t.Fatal("runProvider() error = nil, want unsupported provider")
	}
	if !strings.Contains(fmt.Sprint(err), "unsupported reviewer provider") {
		t.Fatalf("error = %q, want unsupported provider", err)
	}
}

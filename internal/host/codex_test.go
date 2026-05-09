package host

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charlieyou/cerberus/internal/config"
)

func TestNewFromEnvReturnsCodexHost(t *testing.T) {
	adapter, err := NewFromEnv(&config.Env{Host: "codex"})
	if err != nil {
		t.Fatalf("NewFromEnv() returned error: %v", err)
	}
	if _, ok := adapter.(CodexHost); !ok {
		t.Fatalf("NewFromEnv(codex) returned %T, want CodexHost", adapter)
	}
}

func TestCodexStateRootUsesCodexProjectsDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)

	env := &config.Env{ProjectKey: "project-key"}
	got, err := NewCodexHost().StateRoot(env)
	if err != nil {
		t.Fatalf("StateRoot() returned error: %v", err)
	}
	want := filepath.Join(home, ".codex", "projects", "project-key", "cerberus")
	if got != want {
		t.Fatalf("StateRoot() = %q, want %q", got, want)
	}
}

func TestCodexProjectKeyDerivesFromRepoRoot(t *testing.T) {
	repoRoot := t.TempDir()
	if err := os.Mkdir(filepath.Join(repoRoot, ".git"), 0o755); err != nil {
		t.Fatalf("create git marker: %v", err)
	}
	nested := filepath.Join(repoRoot, "pkg", "subpkg")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("create nested directory: %v", err)
	}

	got, err := NewCodexHost().ProjectKey(&config.Env{Root: t.TempDir(), ProjectKey: ""})
	if err != nil {
		t.Fatalf("ProjectKey() with process cwd returned error: %v", err)
	}
	if got == "" {
		t.Fatal("ProjectKey() with process cwd returned empty key")
	}

	got, err = ProjectKeyFromDir(nested)
	if err != nil {
		t.Fatalf("ProjectKeyFromDir() returned error: %v", err)
	}
	sum := sha256.Sum256([]byte(repoRoot))
	want := hex.EncodeToString(sum[:])[:16]
	if got != want {
		t.Fatalf("ProjectKeyFromDir() = %q, want %q", got, want)
	}
}

func TestCodexResolveSessionIDFromPayload(t *testing.T) {
	got, err := NewCodexHost().ResolveSessionID([]byte(`{"session_id":"session-123","transcript_path":"/tmp/transcript.jsonl"}`))
	if err != nil {
		t.Fatalf("ResolveSessionID() returned error: %v", err)
	}
	if got != "session-123" {
		t.Fatalf("ResolveSessionID() = %q, want session-123", got)
	}
}

func TestCodexResolveSessionIDRequiresPayloadField(t *testing.T) {
	_, err := NewCodexHost().ResolveSessionID([]byte(`{"transcript_path":"/tmp/transcript.jsonl"}`))
	if err == nil {
		t.Fatal("ResolveSessionID() error = nil, want non-nil")
	}
	if !strings.Contains(err.Error(), "session_id is required") {
		t.Fatalf("ResolveSessionID() error = %q, want session_id requirement", err)
	}
}

func TestCodexTranscriptPathFromPayload(t *testing.T) {
	got, err := NewCodexHost().TranscriptPath([]byte(`{"session_id":"session-123","transcript_path":"/tmp/transcript.jsonl"}`))
	if err != nil {
		t.Fatalf("TranscriptPath() returned error: %v", err)
	}
	if got != "/tmp/transcript.jsonl" {
		t.Fatalf("TranscriptPath() = %q, want /tmp/transcript.jsonl", got)
	}
}

func TestCodexTranscriptPathRequiresPayloadField(t *testing.T) {
	_, err := NewCodexHost().TranscriptPath([]byte(`{"session_id":"session-123"}`))
	if err == nil {
		t.Fatal("TranscriptPath() error = nil, want non-nil")
	}
	if !strings.Contains(err.Error(), "transcript_path is required") {
		t.Fatalf("TranscriptPath() error = %q, want transcript_path requirement", err)
	}
}

func TestCodexTranscriptPathRequiresAbsolutePath(t *testing.T) {
	_, err := NewCodexHost().TranscriptPath([]byte(`{"session_id":"session-123","transcript_path":"relative.jsonl"}`))
	if err == nil {
		t.Fatal("TranscriptPath() error = nil, want non-nil")
	}
	if !strings.Contains(err.Error(), "must be absolute") {
		t.Fatalf("TranscriptPath() error = %q, want absolute-path requirement", err)
	}
}

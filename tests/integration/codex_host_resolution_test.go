package integration_test

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/host"
	"github.com/charlieyou/cerberus/internal/state"
)

func TestCodexHostResolutionWritesGateStateUnderCodexRoot(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("CERBERUS_HOST", "codex")

	sum := sha256.Sum256([]byte(repoRoot))
	projectKey := hex.EncodeToString(sum[:])[:16]
	runKey := "codex-resolution-session"
	transcriptPath := filepath.Join(home, "codex-resolution-session.jsonl")
	env := &config.Env{
		Host:           "codex",
		Root:           repoRoot,
		SessionID:      runKey,
		TranscriptPath: transcriptPath,
	}
	adapter, err := host.NewFromEnv(env)
	if err != nil {
		t.Fatalf("NewFromEnv() error = %v", err)
	}
	env.ProjectKey, err = adapter.ProjectKey(env)
	if err != nil {
		t.Fatalf("ProjectKey() error = %v", err)
	}
	env.StateRoot, err = adapter.StateRoot(env)
	if err != nil {
		t.Fatalf("StateRoot() error = %v", err)
	}
	env.RunKey = runKey
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	if err := state.WriteGateState(state.GateStatePath(runRoot), &state.GateState{
		RunKey:           env.RunKey,
		Host:             env.Host,
		ProjectKey:       env.ProjectKey,
		SessionID:        env.SessionID,
		TranscriptPath:   env.TranscriptPath,
		Status:           state.StatusPending,
		CurrentIteration: 1,
		MaxRounds:        1,
		Mode:             "smart",
		StartedAt:        time.Now().UTC(),
	}); err != nil {
		t.Fatalf("WriteGateState() error = %v", err)
	}

	gatePath := filepath.Join(home, ".codex", "projects", projectKey, "cerberus", runKey, "gate-state.json")
	gate, err := state.ReadGateState(gatePath)
	if err != nil {
		t.Fatalf("ReadGateState(%s) error = %v", gatePath, err)
	}
	if gate.Host != "codex" {
		t.Fatalf("gate host = %q, want codex", gate.Host)
	}
	if gate.ProjectKey != projectKey {
		t.Fatalf("gate project_key = %q, want %q", gate.ProjectKey, projectKey)
	}
	if gate.SessionID != runKey {
		t.Fatalf("gate session_id = %q, want %q", gate.SessionID, runKey)
	}
	if gate.TranscriptPath != transcriptPath {
		t.Fatalf("gate transcript_path = %q, want %q", gate.TranscriptPath, transcriptPath)
	}
}

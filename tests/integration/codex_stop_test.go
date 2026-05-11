package integration_test

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/host"
	"github.com/charlieyou/cerberus/internal/state"
)

func TestCodexStopHookBlocksUntilGateStateResolves(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}

	stateRoot := t.TempDir()
	projectRoot := t.TempDir()
	if err := os.Mkdir(filepath.Join(projectRoot, ".git"), 0o755); err != nil {
		t.Fatalf("create git marker: %v", err)
	}
	projectKey, err := host.ProjectKeyFromDir(projectRoot)
	if err != nil {
		t.Fatalf("ProjectKeyFromDir() error = %v", err)
	}
	runKey := "codex-stop-poll"
	gatePath := state.GateStatePath(state.RunDir(stateRoot, projectKey, runKey))
	if err := state.WriteGateState(gatePath, &state.GateState{Status: state.StatusPending}); err != nil {
		t.Fatalf("seed pending gate: %v", err)
	}

	go func() {
		time.Sleep(time.Second)
		verdict := state.VerdictPass
		_ = state.WriteGateState(gatePath, &state.GateState{Status: state.StatusResolved, Verdict: &verdict})
	}()

	payload := fmt.Sprintf(`{"session_id":%q,"transcript_path":%q,"workspace_root":%q}`, runKey, filepath.Join(t.TempDir(), "codex-stop-poll.jsonl"), projectRoot)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "go", "run", "./cmd/cerberus", "hook", "codex-stop")
	cmd.Dir = repoRoot
	cmd.Stdin = strings.NewReader(payload)
	cmd.Env = append(os.Environ(),
		"CERBERUS_HOST=codex",
		"CERBERUS_STATE_ROOT="+stateRoot,
		"CERBERUS_PROJECT_KEY="+projectKey,
	)

	started := time.Now()
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("cerberus hook codex-stop failed: %v\n%s", err, output)
	}
	if elapsed := time.Since(started); elapsed < time.Second || elapsed > 10*time.Second {
		t.Fatalf("codex-stop elapsed = %s, want bounded wait for gate transition", elapsed)
	}
}

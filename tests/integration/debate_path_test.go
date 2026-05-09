package integration_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/state"
)

func TestDebatePath(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	binary := filepath.Join(t.TempDir(), "cerberus")
	cmd := exec.Command("go", "build", "-o", binary, "./cmd/cerberus")
	cmd.Dir = repoRoot
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build failed: %v\n%s", err, output)
	}
	recordDir := t.TempDir()
	installDebateMockCLI(t, repoRoot, recordDir)

	env := &config.Env{
		Host:       "generic",
		Root:       repoRoot,
		StateRoot:  t.TempDir(),
		ProjectKey: "integration-project",
		RunKey:     "debate-path",
	}

	verdict, err := (orchestrator.Orchestrator{
		Env: env,
	}).RunDebate(context.Background(), []orchestrator.ReviewerSlot{
		{ID: "codex#1", Provider: "codex", Model: "stub", InstanceIndex: 1},
		{ID: "codex#2", Provider: "codex", Model: "stub", InstanceIndex: 2},
	}, []byte("Review this change."), 2)
	if err != nil {
		t.Fatalf("RunDebate() error = %v", err)
	}
	if verdict.Verdict != state.VerdictPass {
		t.Fatalf("verdict = %q, want pass", verdict.Verdict)
	}
	for _, name := range []string{"invocation-3.stdin", "invocation-4.stdin"} {
		data, err := os.ReadFile(filepath.Join(recordDir, name))
		if err != nil {
			t.Fatalf("ReadFile(%s) error = %v", name, err)
		}
		prompt := string(data)
		if !strings.Contains(prompt, "{{{{PEER_BROADCAST}}}}") || !strings.Contains(prompt, "peer_1") || !strings.Contains(prompt, "peer_2") {
			t.Fatalf("round-2 prompt %s = %q, want peer broadcast substitution", name, prompt)
		}
	}

	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	if _, err := os.Stat(filepath.Join(runRoot, "iterations", "1", "round-2", "peer-broadcast.json")); err != nil {
		t.Fatalf("round-2 peer-broadcast.json missing: %v", err)
	}
	gate, err := state.ReadGateState(state.GateStatePath(runRoot))
	if err != nil {
		t.Fatalf("ReadGateState() error = %v", err)
	}
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictPass {
		t.Fatalf("gate verdict = %v, want pass", gate.Verdict)
	}
}

func installDebateMockCLI(t *testing.T, repoRoot, recordDir string) {
	t.Helper()
	binDir := t.TempDir()
	script := `#!/bin/sh
set -eu
record_dir=${CERBERUS_DEBATE_MOCK_DIR:?}
fixture_dir=${CERBERUS_DEBATE_FIXTURE_DIR:?}
mkdir -p "$record_dir"
while ! mkdir "$record_dir/lock" 2>/dev/null; do sleep 0.01; done
trap 'rmdir "$record_dir/lock"' EXIT
count_file="$record_dir/count"
if [ -f "$count_file" ]; then
  count=$(cat "$count_file")
else
  count=0
fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"
cat > "$record_dir/invocation-$count.stdin"
printf '%s\n' "$@" > "$record_dir/invocation-$count.args"
case "$count" in
  1) cat "$fixture_dir/round-1-codex1.json" ;;
  2) cat "$fixture_dir/round-1-codex2.json" ;;
  3) cat "$fixture_dir/round-2-codex1.json" ;;
  4) cat "$fixture_dir/round-2-codex2.json" ;;
  *) echo "unexpected invocation $count" >&2; exit 1 ;;
esac
`
	path := filepath.Join(binDir, "codex")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("WriteFile(mock codex) error = %v", err)
	}
	t.Setenv("CERBERUS_DEBATE_MOCK_DIR", recordDir)
	t.Setenv("CERBERUS_DEBATE_FIXTURE_DIR", filepath.Join(repoRoot, "tests", "fixtures", "debate"))
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

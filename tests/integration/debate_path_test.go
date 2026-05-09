package integration_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/reviewer"
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
	setMockPath(t, repoRoot)

	env := &config.Env{
		Host:       "generic",
		Root:       repoRoot,
		StateRoot:  t.TempDir(),
		ProjectKey: "integration-project",
		RunKey:     "debate-path",
	}
	spawner := &fixtureDebateSpawner{
		fixtureDir: filepath.Join(repoRoot, "tests", "fixtures", "debate"),
		prompts:    map[string]string{},
	}

	verdict, err := (orchestrator.Orchestrator{
		Env:     env,
		Spawner: spawner,
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
	for _, id := range []string{"codex#1", "codex#2"} {
		prompt := spawner.prompts[id+":2"]
		if !strings.Contains(prompt, "{{{{PEER_BROADCAST}}}}") || !strings.Contains(prompt, "peer_1") || !strings.Contains(prompt, "peer_2") {
			t.Fatalf("round-2 prompt for %s = %q, want peer broadcast substitution", id, prompt)
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

type fixtureDebateSpawner struct {
	fixtureDir string
	mu         sync.Mutex
	prompts    map[string]string
}

func (spawner *fixtureDebateSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	spawner.mu.Lock()
	defer spawner.mu.Unlock()

	key := fmt.Sprintf("%s:%d", request.ID, request.Round)
	spawner.prompts[key] = string(request.User)
	file := "round-1-codex1.json"
	switch {
	case request.Round == 1 && request.ID == "codex#2":
		file = "round-1-codex2.json"
	case request.Round == 2 && request.ID == "codex#1":
		file = "round-2-codex1.json"
	case request.Round == 2 && request.ID == "codex#2":
		file = "round-2-codex2.json"
	}
	output, err := os.ReadFile(filepath.Join(spawner.fixtureDir, file))
	if err != nil {
		return reviewer.Response{}, err
	}
	var parsed reviewer.RawReviewerOutput
	if err := json.Unmarshal(output, &parsed); err != nil {
		return reviewer.Response{}, err
	}
	return reviewer.Response{ID: request.ID, Output: output, Parsed: &parsed}, nil
}

func setMockPath(t *testing.T, repoRoot string) {
	t.Helper()
	t.Setenv("PATH", filepath.Join(repoRoot, "tests", "mocks")+string(os.PathListSeparator)+os.Getenv("PATH"))
}

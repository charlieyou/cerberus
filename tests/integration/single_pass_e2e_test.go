package integration_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/hook"
	"github.com/charlieyou/cerberus/internal/host"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/state"
)

func TestSinglePassReviewResolvesStopHookGate(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	t.Setenv("PATH", integrationMockPath(t, repoRoot)+string(os.PathListSeparator)+os.Getenv("PATH"))

	ctx := context.Background()
	env := &config.Env{
		Host:       "claude",
		Root:       repoRoot,
		StateRoot:  t.TempDir(),
		ProjectKey: "integration-project",
		RunKey:     "single-pass-review",
	}
	params := orchestrator.Params{
		Prompt: []byte("Review this small change."),
		Reviewers: []orchestrator.ReviewerSlot{
			{ID: "claude#1", Provider: "claude", Model: "stub"},
			{ID: "codex#1", Provider: "codex", Model: "stub"},
			{ID: "gemini#1", Provider: "gemini", Model: "stub"},
		},
	}

	if err := orchestrator.RunSinglePass(ctx, env, params, passReviewerStub{env: env}); err != nil {
		t.Fatalf("RunSinglePass failed: %v", err)
	}

	gate, err := state.ReadGateState(gateStatePath(env))
	if err != nil {
		t.Fatalf("ReadGateState failed: %v", err)
	}
	if gate.Status != state.GateStateResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.GateStateResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != "pass" {
		t.Fatalf("gate verdict = %v, want pass", gate.Verdict)
	}
	if err := hook.PollGateState(gateStatePath(env), 100*time.Millisecond, 5*time.Second); err != nil {
		t.Fatalf("Stop hook poll failed: %v", err)
	}
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	for _, reviewerID := range []string{"claude#1", "codex#1", "gemini#1"} {
		assertReviewerTelemetryID(t, runRoot, reviewerID)
	}
	for _, name := range []string{
		filepath.Join("iterations", "1", "round-1", "round-telemetry.json"),
		filepath.Join("iterations", "1", "iteration-telemetry.json"),
		"run-telemetry.json",
	} {
		if _, err := os.Stat(filepath.Join(runRoot, name)); err != nil {
			t.Fatalf("%s missing: %v", name, err)
		}
	}
}

func TestSinglePassCLIWaitResolveStatusWithDefaultPanel(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	stateRoot := t.TempDir()
	recordDir := t.TempDir()
	projectRoot := initIntegrationGitRepo(t)
	home := t.TempDir()
	env := []string{
		"CERBERUS_HOST=generic",
		"CERBERUS_ROOT=" + repoRoot,
		"CERBERUS_STATE_ROOT=" + stateRoot,
		"CERBERUS_PROJECT_KEY=single-pass-cli",
		"CERBERUS_RUN_KEY=default-panel",
		"CERBERUS_MOCK_RECORD_DIR=" + recordDir,
		"HOME=" + home,
		"XDG_CONFIG_HOME=" + filepath.Join(home, ".config"),
		"PATH=" + integrationMockPath(t, repoRoot) + string(os.PathListSeparator) + os.Getenv("PATH"),
	}

	runIntegrationCommand(t, projectRoot, env, binary, "spawn-code-review", "Review this small default-panel change.")
	waitOutput := runIntegrationCommand(t, projectRoot, env, binary, "wait", "--timeout", "5", "--poll-interval", "1")
	if !strings.Contains(waitOutput, "status: resolved") || !strings.Contains(waitOutput, "verdict: pass") {
		t.Fatalf("wait output = %q, want resolved pass status", waitOutput)
	}
	resolveOutput := runIntegrationCommand(t, projectRoot, env, binary, "resolve", "--reason", "integration confirms resolved gate remains resolvable")
	if !strings.Contains(resolveOutput, "resolved") {
		t.Fatalf("resolve output = %q, want resolved", resolveOutput)
	}
	statusOutput := runIntegrationCommand(t, projectRoot, env, binary, "status")
	if !strings.Contains(statusOutput, "status: resolved") || !strings.Contains(statusOutput, "verdict: pass") {
		t.Fatalf("status output = %q, want resolved pass status", statusOutput)
	}

	runRoot := filepath.Join(stateRoot, "single-pass-cli", "default-panel")
	for _, reviewerID := range []string{"claude#1", "codex#1", "gemini#1"} {
		assertReviewerTelemetryID(t, runRoot, reviewerID)
	}
	claudeArgs, err := os.ReadFile(filepath.Join(recordDir, "claude.args"))
	if err != nil {
		t.Fatalf("ReadFile(claude.args) error = %v", err)
	}
	if !strings.Contains(string(claudeArgs), "--restricted\n--tools\nRead,Grep,Glob\n") {
		t.Fatalf("claude reviewer args = %q, want restricted read-only tools", claudeArgs)
	}
}

func TestCodexHookEndToEndSingleSlotSmoke(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	t.Setenv("PATH", integrationMockPath(t, repoRoot)+string(os.PathListSeparator)+os.Getenv("PATH"))

	ctx := context.Background()
	stateRoot := t.TempDir()
	projectRoot := t.TempDir()
	if err := os.Mkdir(filepath.Join(projectRoot, ".git"), 0o755); err != nil {
		t.Fatalf("create git marker: %v", err)
	}
	projectKey, err := host.ProjectKeyFromDir(projectRoot)
	if err != nil {
		t.Fatalf("ProjectKeyFromDir() error = %v", err)
	}
	runKey := "codex-hook-smoke"
	payload := fmt.Sprintf(`{"session_id":%q,"transcript_path":%q,"workspace_root":%q}`, runKey, filepath.Join(t.TempDir(), "codex-hook-smoke.jsonl"), projectRoot)

	runCerberusHook(t, repoRoot, stateRoot, projectKey, "codex-session-start", payload)
	if _, err := os.Stat(filepath.Join(stateRoot, projectKey, runKey, "session.json")); err != nil {
		t.Fatalf("codex session-start did not initialize session.json: %v", err)
	}

	env := &config.Env{
		Host:       "codex",
		Root:       repoRoot,
		StateRoot:  stateRoot,
		ProjectKey: projectKey,
		RunKey:     runKey,
	}
	params := orchestrator.Params{
		Prompt: []byte("Review this small Codex-hosted change."),
		Reviewers: []orchestrator.ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}
	if err := orchestrator.RunSinglePass(ctx, env, params, passReviewerStub{env: env}); err != nil {
		t.Fatalf("RunSinglePass failed: %v", err)
	}

	runCerberusHook(t, repoRoot, stateRoot, projectKey, "codex-stop", payload)
	gate, err := state.ReadGateState(gateStatePath(env))
	if err != nil {
		t.Fatalf("ReadGateState failed: %v", err)
	}
	if gate.Status != state.GateStateResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.GateStateResolved)
	}
	if _, err := os.Stat(filepath.Join(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey), "iterations", "1", "round-1", "reviewers", "codex#1", "telemetry.json")); err != nil {
		t.Fatalf("codex reviewer telemetry missing: %v", err)
	}
}

func runCerberusHook(t *testing.T, repoRoot, stateRoot, projectKey, subcommand, payload string) {
	t.Helper()

	cmd := exec.Command("go", "run", "./cmd/cerberus", "hook", subcommand)
	cmd.Dir = repoRoot
	cmd.Stdin = strings.NewReader(payload)
	cmd.Env = append(os.Environ(),
		"CERBERUS_HOST=codex",
		"CERBERUS_STATE_ROOT="+stateRoot,
		"CERBERUS_PROJECT_KEY="+projectKey,
	)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("cerberus hook %s failed: %v\n%s", subcommand, err, output)
	}
}

func runIntegrationCommand(t *testing.T, dir string, env []string, binary string, args ...string) string {
	t.Helper()
	cmd := exec.Command(binary, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), env...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("cerberus %s failed: %v\n%s", strings.Join(args, " "), err, output)
	}
	return string(output)
}

func assertReviewerTelemetryID(t *testing.T, runRoot, reviewerID string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", reviewerID, "telemetry.json"))
	if err != nil {
		t.Fatalf("reviewer telemetry for %s missing: %v", reviewerID, err)
	}
	var row struct {
		ReviewerID string `json:"reviewer_id"`
	}
	if err := json.Unmarshal(data, &row); err != nil {
		t.Fatalf("Unmarshal(%s telemetry) error = %v", reviewerID, err)
	}
	if row.ReviewerID != reviewerID {
		t.Fatalf("%s telemetry reviewer_id = %q, want %q", reviewerID, row.ReviewerID, reviewerID)
	}
}

type passReviewerStub struct {
	env *config.Env
}

func (stub passReviewerStub) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	gate, err := state.ReadGateState(gateStatePath(stub.env))
	if err != nil {
		return reviewer.Response{}, fmt.Errorf("read gate state during reviewer spawn: %w", err)
	}
	if gate.Status != state.GateStatePending {
		return reviewer.Response{}, fmt.Errorf("gate status during reviewer spawn = %q, want %q", gate.Status, state.GateStatePending)
	}

	output, err := json.Marshal(reviewer.RawReviewerOutput{
		Findings: []reviewer.RawFinding{},
	})
	if err != nil {
		return reviewer.Response{}, err
	}
	return reviewer.Response{ID: request.ID, Output: output}, nil
}

func gateStatePath(env *config.Env) string {
	return state.GateStatePath(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey))
}

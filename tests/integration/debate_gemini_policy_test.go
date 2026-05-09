package integration_test

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charlieyou/cerberus/internal/aggregate"
	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/state"
)

func TestDebateGeminiPolicy(t *testing.T) {
	t.Run("mixed codex gemini panel", func(t *testing.T) {
		repoRoot := integrationRepoRoot(t)
		installMultiDebateMockCLI(t, repoRoot, t.TempDir())
		env := debatePolicyEnv(t, repoRoot, "debate-gemini-policy-mixed")

		_, err := (orchestrator.Orchestrator{
			Env:       env,
			Consensus: aggregate.ModeMajority,
		}).RunDebate(context.Background(), []orchestrator.ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "gpt-5.5", Strategy: "verification-first", InstanceIndex: 1},
			{ID: "gemini#1", Provider: "gemini", Model: "gemini-3.1-pro", InstanceIndex: 1},
		}, []byte("Review Gemini policy in mixed debate."), 2)
		if err != nil {
			t.Fatalf("RunDebate() error = %v", err)
		}

		runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
		assertResolvedGate(t, runRoot)
		assertGeminiPolicyInReviewerStderr(t, runRoot, "gemini#1")
	})

	t.Run("two gemini panel", func(t *testing.T) {
		repoRoot := integrationRepoRoot(t)
		recordDir := t.TempDir()
		installMultiDebateMockCLI(t, repoRoot, recordDir)
		env := debatePolicyEnv(t, repoRoot, "debate-gemini-policy-double")

		_, err := (orchestrator.Orchestrator{
			Env:       env,
			Consensus: aggregate.ModeMajority,
		}).RunDebate(context.Background(), []orchestrator.ReviewerSlot{
			{ID: "gemini#1", Provider: "gemini", Model: "gemini-3.1-pro", InstanceIndex: 1},
			{ID: "gemini#2", Provider: "gemini", Model: "gemini-3.1-pro", InstanceIndex: 2},
		}, []byte("Review Gemini policy in same-provider debate."), 2)
		if err != nil {
			t.Fatalf("RunDebate() error = %v", err)
		}

		runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
		assertResolvedGate(t, runRoot)
		assertGeminiPolicyInReviewerStderr(t, runRoot, "gemini#1")
		assertGeminiPolicyInReviewerStderr(t, runRoot, "gemini#2")
		assertGeminiMockInvocations(t, runRoot, recordDir, []string{"gemini#1", "gemini#2"}, 4)
	})
}

func debatePolicyEnv(t *testing.T, repoRoot, runKey string) *config.Env {
	t.Helper()
	return &config.Env{
		Host:       "generic",
		Root:       repoRoot,
		StateRoot:  t.TempDir(),
		ProjectKey: "integration-project",
		RunKey:     runKey,
	}
}

func assertGeminiMockInvocations(t *testing.T, runRoot, recordDir string, instanceIDs []string, want int) {
	t.Helper()
	policyPath := filepath.Join(integrationRepoRoot(t), "config", "gemini-readonly-policy.toml")
	for _, instanceID := range instanceIDs {
		for _, round := range []int{1, 2} {
			path := filepath.Join(runRoot, "iterations", "1", fmt.Sprintf("round-%d", round), "reviewers", instanceID, "stderr.log")
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("ReadFile(%s) error = %v", path, err)
			}
			text := string(data)
			if !strings.Contains(text, "--policy-file") || !strings.Contains(text, policyPath) {
				t.Fatalf("%s = %q, want --policy-file %s", path, text, policyPath)
			}
		}
	}

	data, err := os.ReadFile(filepath.Join(recordDir, "count"))
	if err != nil {
		t.Fatalf("ReadFile(mock count) error = %v", err)
	}
	got := strings.TrimSpace(string(data))
	if got != fmt.Sprint(want) {
		t.Fatalf("mock invocation count = %s, want %d", got, want)
	}
	for invocation := 1; invocation <= want; invocation++ {
		data, err := os.ReadFile(filepath.Join(recordDir, fmt.Sprintf("invocation-%d.provider", invocation)))
		if err != nil {
			t.Fatalf("ReadFile(invocation-%d.provider) error = %v", invocation, err)
		}
		if strings.TrimSpace(string(data)) != "gemini" {
			t.Fatalf("invocation-%d provider = %q, want gemini", invocation, strings.TrimSpace(string(data)))
		}
	}
}

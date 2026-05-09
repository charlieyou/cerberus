package reviewer

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/roster"
	"github.com/charlieyou/cerberus/internal/state"
)

// Runner spawns provider CLIs and persists per-reviewer artifacts.
type Runner struct {
	Root      string
	RunRoot   string
	Iteration int
	Round     int
}

// Spawn invokes a reviewer from a roster slot using environment-derived state.
func Spawn(ctx context.Context, slot roster.RosterSlot, system, user []byte) (*RawReviewerOutput, error) {
	env := config.Resolve()
	runRoot := ""
	if env.StateRoot != "" && env.ProjectKey != "" && env.RunKey != "" {
		runRoot = state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	}
	root := env.Root
	if root == "" {
		var err error
		root, err = os.Getwd()
		if err != nil {
			return nil, fmt.Errorf("resolve current directory: %w", err)
		}
	}
	response, err := (Runner{
		Root:      root,
		RunRoot:   runRoot,
		Iteration: 1,
		Round:     1,
	}).Spawn(ctx, Request{
		ID:       slot.InstanceID,
		Provider: slot.Provider,
		Model:    slot.Model,
		System:   system,
		User:     user,
	})
	if err != nil {
		return nil, err
	}
	return response.Parsed, nil
}

func (runner Runner) Spawn(ctx context.Context, request Request) (Response, error) {
	if request.ID == "" {
		return Response{}, fmt.Errorf("reviewer instance ID is required")
	}
	user := request.User
	if user == nil {
		user = request.Prompt
	}
	command, err := runner.command(ctx, request, user)
	if err != nil {
		return Response{}, err
	}
	command.Stdin = bytes.NewReader(user)

	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	runRoot := firstNonEmpty(request.RunRoot, runner.RunRoot)
	iteration := firstPositive(request.Iteration, runner.Iteration, 1)
	round := firstPositive(request.Round, runner.Round, 1)
	reviewerDir := ""
	if runRoot != "" {
		reviewerDir = state.ReviewerDir(runRoot, iteration, round, request.ID)
		if err := os.MkdirAll(reviewerDir, 0o755); err != nil {
			return Response{}, fmt.Errorf("create reviewer directory: %w", err)
		}
		if err := os.WriteFile(filepath.Join(reviewerDir, "prompt.md"), user, 0o644); err != nil {
			return Response{}, fmt.Errorf("write reviewer prompt: %w", err)
		}
	}

	runErr := command.Run()
	if reviewerDir != "" {
		if err := os.WriteFile(filepath.Join(reviewerDir, "stdout.log"), stdout.Bytes(), 0o644); err != nil {
			return Response{}, fmt.Errorf("write reviewer stdout log: %w", err)
		}
		if err := os.WriteFile(filepath.Join(reviewerDir, "stderr.log"), stderr.Bytes(), 0o644); err != nil {
			return Response{}, fmt.Errorf("write reviewer stderr log: %w", err)
		}
	}
	if runErr != nil {
		return Response{}, fmt.Errorf("reviewer %s failed: %w; stderr: %s", request.ID, runErr, stderr.String())
	}

	parsed, err := Parse(stdout.Bytes())
	if err != nil {
		return Response{}, err
	}
	outputJSON, err := json.MarshalIndent(parsed, "", "  ")
	if err != nil {
		return Response{}, fmt.Errorf("marshal reviewer output: %w", err)
	}
	outputJSON = append(outputJSON, '\n')
	if runRoot != "" {
		if err := state.WriteReviewerOutput(runRoot, iteration, round, request.ID, outputJSON); err != nil {
			return Response{}, err
		}
	}
	return Response{ID: request.ID, Output: outputJSON, Parsed: parsed}, nil
}

func (runner Runner) command(ctx context.Context, request Request, user []byte) (*exec.Cmd, error) {
	if bytes.Contains([]byte(request.Provider), []byte{0}) || bytes.Contains([]byte(request.Model), []byte{0}) || bytes.Contains(request.System, []byte{0}) {
		return nil, fmt.Errorf("reviewer command contains NUL byte")
	}
	if bytes.Contains(user, []byte{0}) {
		return nil, fmt.Errorf("reviewer user prompt contains NUL byte")
	}

	args := []string{}
	switch request.Provider {
	case "claude":
		args = []string{"--print", "--output-format", "json", "--append-system-prompt", string(request.System)}
	case "codex":
		args = []string{"--json", "--model", request.Model, "--append-system-prompt", string(request.System)}
	case "gemini":
		root := firstNonEmpty(request.Root, runner.Root)
		if root == "" {
			return nil, fmt.Errorf("CERBERUS_ROOT is required for gemini policy file")
		}
		policyPath := filepath.Join(root, "config", "gemini-readonly-policy.toml")
		if _, err := os.Stat(policyPath); err != nil {
			return nil, fmt.Errorf("gemini policy file %s is required: %w", policyPath, err)
		}
		args = []string{"--json", "--model", request.Model, "--append-system-prompt", string(request.System), "--policy-file", policyPath}
	default:
		return nil, fmt.Errorf("unsupported reviewer provider %q", request.Provider)
	}
	return exec.CommandContext(ctx, request.Provider, args...), nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func firstPositive(values ...int) int {
	for _, value := range values {
		if value > 0 {
			return value
		}
	}
	return 0
}

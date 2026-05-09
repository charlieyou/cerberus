package reviewer

import (
	"bufio"
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

	tokens, costUSD := extractUsage(stdout.Bytes())
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
	return Response{ID: request.ID, Output: outputJSON, Parsed: parsed, Tokens: tokens, CostUSD: costUSD}, nil
}

func extractUsage(stdout []byte) (Tokens, float64) {
	if tokens, costUSD, ok := extractUsageObject(stdout); ok {
		return tokens, costUSD
	}

	var total Tokens
	var totalCostUSD float64
	scanner := bufio.NewScanner(bytes.NewReader(stdout))
	scanner.Buffer(make([]byte, 0, 64*1024), 10*1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		tokens, costUSD, ok := extractUsageObject(line)
		if !ok {
			continue
		}
		total.Input += tokens.Input
		total.Output += tokens.Output
		totalCostUSD += costUSD
	}
	return total, totalCostUSD
}

func extractUsageObject(data []byte) (Tokens, float64, bool) {
	var payload usagePayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return Tokens{}, 0, false
	}
	return payload.tokens(), payload.costUSD(), true
}

type usagePayload struct {
	Tokens usageTokens `json:"tokens"`
	Usage  struct {
		InputTokens      int `json:"input_tokens"`
		PromptTokens     int `json:"prompt_tokens"`
		OutputTokens     int `json:"output_tokens"`
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
	CostUSD      float64 `json:"cost_usd"`
	Cost         float64 `json:"cost"`
	TotalCostUSD float64 `json:"total_cost_usd"`
	Stats        struct {
		Cost   float64               `json:"cost"`
		Models map[string]modelUsage `json:"models"`
	} `json:"stats"`
}

type usageTokens struct {
	Input      int `json:"input"`
	Output     int `json:"output"`
	Candidates int `json:"candidates"`
}

type modelUsage struct {
	Tokens usageTokens `json:"tokens"`
}

func (payload usagePayload) tokens() Tokens {
	tokens := Tokens{
		Input:  firstPositive(payload.Tokens.Input, payload.Usage.InputTokens, payload.Usage.PromptTokens),
		Output: firstPositive(payload.Tokens.Output, payload.Tokens.Candidates, payload.Usage.OutputTokens, payload.Usage.CompletionTokens),
	}
	if tokens.Input > 0 || tokens.Output > 0 {
		return tokens
	}
	for _, model := range payload.Stats.Models {
		tokens.Input += model.Tokens.Input
		tokens.Output += firstPositive(model.Tokens.Output, model.Tokens.Candidates)
	}
	return tokens
}

func (payload usagePayload) costUSD() float64 {
	return firstPositiveFloat(payload.CostUSD, payload.TotalCostUSD, payload.Cost, payload.Stats.Cost)
}

func (runner Runner) command(ctx context.Context, request Request, user []byte) (*exec.Cmd, error) {
	system := systemPromptWithMode(request.System, request.Mode)
	if bytes.Contains([]byte(request.Provider), []byte{0}) || bytes.Contains([]byte(request.Model), []byte{0}) || bytes.Contains(system, []byte{0}) {
		return nil, fmt.Errorf("reviewer command contains NUL byte")
	}
	if bytes.Contains(user, []byte{0}) {
		return nil, fmt.Errorf("reviewer user prompt contains NUL byte")
	}

	args := []string{}
	switch request.Provider {
	case "claude":
		args = []string{"--print", "--output-format", "json", "--model", request.Model, "--append-system-prompt", string(system)}
	case "codex":
		args = []string{"--json", "--model", request.Model, "--append-system-prompt", string(system)}
	case "gemini":
		root := firstNonEmpty(request.Root, runner.Root)
		if root == "" {
			return nil, fmt.Errorf("CERBERUS_ROOT is required for gemini policy file")
		}
		policyPath := filepath.Join(root, "config", "gemini-readonly-policy.toml")
		if _, err := os.Stat(policyPath); err != nil {
			return nil, fmt.Errorf("gemini policy file %s is required: %w", policyPath, err)
		}
		args = []string{"--json", "--model", request.Model, "--append-system-prompt", string(system), "--policy-file", policyPath}
	default:
		return nil, fmt.Errorf("unsupported reviewer provider %q", request.Provider)
	}
	return exec.CommandContext(ctx, request.Provider, args...), nil
}

func systemPromptWithMode(system []byte, mode string) []byte {
	if mode == "" {
		return system
	}
	directive := []byte("Cerberus review mode: " + mode + ".")
	if len(system) == 0 {
		return directive
	}
	return bytes.Join([][]byte{system, directive}, []byte("\n\n"))
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

func firstPositiveFloat(values ...float64) float64 {
	for _, value := range values {
		if value > 0 {
			return value
		}
	}
	return 0
}

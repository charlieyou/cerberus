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

	output, runErr := RunProvider(ctx, ProviderInvocation{
		Label:              "reviewer " + request.ID,
		InstanceID:         request.ID,
		Provider:           request.Provider,
		Model:              request.Model,
		Mode:               request.Mode,
		System:             request.System,
		User:               user,
		Root:               firstNonEmpty(request.Root, runner.Root),
		ClaudeOutputFormat: "json",
		ClaudeModelFlag:    true,
	})
	if reviewerDir != "" {
		if err := os.WriteFile(filepath.Join(reviewerDir, "stdout.log"), output.Stdout, 0o644); err != nil {
			return Response{}, fmt.Errorf("write reviewer stdout log: %w", err)
		}
		if err := os.WriteFile(filepath.Join(reviewerDir, "stderr.log"), output.Stderr, 0o644); err != nil {
			return Response{}, fmt.Errorf("write reviewer stderr log: %w", err)
		}
	}
	if runErr != nil {
		return Response{}, runErr
	}

	tokens, costUSD := extractUsage(output.Stdout)
	parsed, err := Parse(output.Stdout)
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

// RunProvider invokes a supported model provider with the user prompt on stdin.
func RunProvider(ctx context.Context, invocation ProviderInvocation) (ProviderOutput, error) {
	command, err := command(ctx, invocation)
	if err != nil {
		return ProviderOutput{}, err
	}
	command.Stdin = bytes.NewReader(invocation.User)

	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	if err := command.Run(); err != nil {
		return ProviderOutput{Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}, fmt.Errorf("%s failed: %w; stderr: %s", firstNonEmpty(invocation.Label, invocation.Provider), err, stderr.String())
	}
	return ProviderOutput{Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}, nil
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

func command(ctx context.Context, invocation ProviderInvocation) (*exec.Cmd, error) {
	system := systemPromptWithMode(invocation.System, invocation.Mode)
	if bytes.Contains([]byte(invocation.Provider), []byte{0}) || bytes.Contains([]byte(invocation.Model), []byte{0}) || bytes.Contains(system, []byte{0}) {
		return nil, fmt.Errorf("reviewer command contains NUL byte")
	}
	if bytes.Contains(invocation.User, []byte{0}) {
		return nil, fmt.Errorf("reviewer user prompt contains NUL byte")
	}

	args := []string{}
	switch invocation.Provider {
	case "claude":
		outputFormat := firstNonEmpty(invocation.ClaudeOutputFormat, "json")
		args = []string{"--print", "--output-format", outputFormat}
		if invocation.ClaudeModelFlag {
			args = append(args, "--model", invocation.Model)
		}
		args = append(args, "--append-system-prompt", string(system))
	case "codex":
		args = []string{"exec", "--json", "--model", invocation.Model, string(system)}
	case "gemini":
		if invocation.Root == "" {
			return nil, fmt.Errorf("CERBERUS_ROOT is required for gemini policy file")
		}
		policyPath := filepath.Join(invocation.Root, "config", "gemini-readonly-policy.toml")
		if _, err := os.Stat(policyPath); err != nil {
			return nil, fmt.Errorf("gemini policy file %s is required: %w", policyPath, err)
		}
		args = []string{"--output-format", "json", "--model", invocation.Model, "--prompt", string(system), "--policy", policyPath}
	default:
		return nil, fmt.Errorf("unsupported reviewer provider %q", invocation.Provider)
	}
	command := exec.CommandContext(ctx, invocation.Provider, args...)
	if invocation.InstanceID != "" {
		command.Env = append(os.Environ(), "CERBERUS_MOCK_INSTANCE_ID="+invocation.InstanceID)
	}
	return command, nil
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

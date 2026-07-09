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
	"strings"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/roster"
	"github.com/charlieyou/cerberus/internal/state"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

const geminiToolNameDirective = "Gemini tool-use constraint: when calling local tools, use only the exact function names `glob`, `grep_search`, or `read_file`; do not add trailing punctuation such as a colon to the tool/function name."

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
		Effort:   slot.Effort,
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

	stdoutPath := ""
	stderrPath := ""
	if reviewerDir != "" {
		stdoutPath = filepath.Join(reviewerDir, "stdout.log")
		stderrPath = filepath.Join(reviewerDir, "stderr.log")
	}
	processStartedAt := time.Now().UTC()
	writeReviewerProcessEvent(runRoot, telemetry.EventReviewerProcessLaunching, request, iteration, round, processStartedAt, map[string]any{
		"stdout_path": stdoutPath,
		"stderr_path": stderrPath,
	})
	output, runErr := RunProvider(ctx, ProviderInvocation{
		Label:              "reviewer " + request.ID,
		InstanceID:         request.ID,
		Provider:           request.Provider,
		Model:              request.Model,
		Effort:             request.Effort,
		Mode:               request.Mode,
		System:             request.System,
		User:               user,
		Root:               firstNonEmpty(request.Root, runner.Root),
		ClaudeOutputFormat: "json",
		ClaudeModelFlag:    true,
		OnStart: func(pid int) {
			writeReviewerProcessEvent(runRoot, telemetry.EventReviewerProcessStarted, request, iteration, round, time.Now().UTC(), map[string]any{
				"pid":         pid,
				"stdout_path": stdoutPath,
				"stderr_path": stderrPath,
			})
		},
	})
	if reviewerDir != "" {
		if err := os.WriteFile(stdoutPath, output.Stdout, 0o644); err != nil {
			return Response{}, fmt.Errorf("write reviewer stdout log: %w", err)
		}
		if err := os.WriteFile(stderrPath, output.Stderr, 0o644); err != nil {
			return Response{}, fmt.Errorf("write reviewer stderr log: %w", err)
		}
	}
	if runErr != nil {
		writeReviewerProcessEvent(runRoot, telemetry.EventReviewerProcessFailed, request, iteration, round, time.Now().UTC(), map[string]any{
			"pid":          output.PID,
			"stdout_path":  stdoutPath,
			"stderr_path":  stderrPath,
			"stdout_bytes": len(output.Stdout),
			"stderr_bytes": len(output.Stderr),
			"duration_ms":  time.Since(processStartedAt).Milliseconds(),
			"error":        runErr.Error(),
		})
		return Response{}, runErr
	}
	writeReviewerProcessEvent(runRoot, telemetry.EventReviewerProcessCompleted, request, iteration, round, time.Now().UTC(), map[string]any{
		"pid":          output.PID,
		"stdout_path":  stdoutPath,
		"stderr_path":  stderrPath,
		"stdout_bytes": len(output.Stdout),
		"stderr_bytes": len(output.Stderr),
		"duration_ms":  time.Since(processStartedAt).Milliseconds(),
	})

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
	command, cleanup, err := command(ctx, invocation)
	if err != nil {
		return ProviderOutput{}, err
	}
	defer cleanup()
	command.Stdin = bytes.NewReader(invocation.User)

	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr

	if err := command.Start(); err != nil {
		return ProviderOutput{Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}, fmt.Errorf("%s failed to start: %w; stderr: %s", firstNonEmpty(invocation.Label, invocation.Provider), err, stderr.String())
	}
	pid := command.Process.Pid
	if invocation.OnStart != nil {
		invocation.OnStart(pid)
	}
	if err := command.Wait(); err != nil {
		return ProviderOutput{PID: pid, Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}, providerRunError(firstNonEmpty(invocation.Label, invocation.Provider), err, stdout.Bytes(), stderr.String())
	}
	return ProviderOutput{PID: pid, Stdout: stdout.Bytes(), Stderr: stderr.Bytes()}, nil
}

func providerRunError(label string, err error, stdout []byte, stderr string) error {
	if stdoutError := stdoutErrorMessage(stdout); stdoutError != "" {
		return fmt.Errorf("%s failed: %w; stderr: %s; stdout error: %s", label, err, stderr, stdoutError)
	}
	return fmt.Errorf("%s failed: %w; stderr: %s", label, err, stderr)
}

func stdoutErrorMessage(stdout []byte) string {
	scanner := bufio.NewScanner(bytes.NewReader(stdout))
	scanner.Buffer(make([]byte, 0, 64*1024), 10*1024*1024)
	var messages []string
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var event struct {
			Type    string `json:"type"`
			Message string `json:"message"`
			Error   struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal(line, &event); err != nil {
			continue
		}
		message := strings.TrimSpace(firstNonEmpty(event.Error.Message, event.Message))
		if message == "" {
			continue
		}
		switch event.Type {
		case "error", "turn.failed":
			messages = append(messages, message)
		}
	}
	if len(messages) == 0 {
		return ""
	}
	return messages[len(messages)-1]
}

func writeReviewerProcessEvent(runRoot string, eventName string, request Request, iteration, round int, at time.Time, extra map[string]any) {
	if runRoot == "" {
		return
	}
	payload := map[string]any{
		"reviewer_id": request.ID,
		"provider":    request.Provider,
		"model":       request.Model,
		"iteration":   firstPositive(iteration, 1),
		"round":       firstPositive(round, 1),
	}
	for key, value := range extra {
		payload[key] = value
	}
	_ = telemetry.WriteEvent(runRoot, telemetry.Event{
		Event:     eventName,
		Timestamp: at,
		Payload:   payload,
	})
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

func command(ctx context.Context, invocation ProviderInvocation) (*exec.Cmd, func(), error) {
	system := systemPromptWithMode(invocation.System, invocation.Mode)
	if bytes.Contains([]byte(invocation.Provider), []byte{0}) || bytes.Contains([]byte(invocation.Model), []byte{0}) || bytes.Contains(system, []byte{0}) {
		return nil, func() {}, fmt.Errorf("reviewer command contains NUL byte")
	}
	if bytes.Contains(invocation.User, []byte{0}) {
		return nil, func() {}, fmt.Errorf("reviewer user prompt contains NUL byte")
	}

	args := []string{}
	cleanup := func() {}
	env := os.Environ()
	switch invocation.Provider {
	case "claude":
		outputFormat := firstNonEmpty(invocation.ClaudeOutputFormat, "json")
		args = []string{"--print", "--output-format", outputFormat}
		if invocation.ClaudeModelFlag {
			args = append(args, "--model", invocation.Model)
		}
		if invocation.Effort != "" {
			args = append(args, "--effort", invocation.Effort)
		}
		args = append(args, "--append-system-prompt", string(system))
	case "codex":
		args = []string{"exec", "--json", "--model", invocation.Model}
		if invocation.Effort != "" {
			args = append(args, "-c", "model_reasoning_effort=\""+invocation.Effort+"\"")
		}
		args = append(args, string(system))
	case "gemini":
		if invocation.Root == "" {
			return nil, func() {}, fmt.Errorf("CERBERUS_ROOT is required for gemini policy file")
		}
		policyPath := filepath.Join(invocation.Root, "config", "gemini-readonly-policy.toml")
		if _, err := os.Stat(policyPath); err != nil {
			return nil, func() {}, fmt.Errorf("gemini policy file %s is required: %w", policyPath, err)
		}
		model := invocation.Model
		if invocation.Effort != "" {
			settingsPath, err := writeGeminiEffortSettings(invocation.Model, strings.ToUpper(invocation.Effort))
			if err != nil {
				return nil, func() {}, err
			}
			cleanup = func() { _ = os.Remove(settingsPath) }
			env = append(env, "GEMINI_CLI_SYSTEM_SETTINGS_PATH="+settingsPath)
			model = geminiEffortModelAlias
		}
		system = withGeminiToolNameDirective(system)
		args = []string{"--output-format", "json", "--model", model, "--prompt", string(system), "--policy", policyPath}
	default:
		return nil, func() {}, fmt.Errorf("unsupported reviewer provider %q", invocation.Provider)
	}
	command := exec.CommandContext(ctx, invocation.Provider, args...)
	if invocation.InstanceID != "" {
		env = append(env, "CERBERUS_MOCK_INSTANCE_ID="+invocation.InstanceID)
	}
	command.Env = env
	return command, cleanup, nil
}

const geminiEffortModelAlias = "cerberus-reviewer"

func writeGeminiEffortSettings(model, thinkingLevel string) (string, error) {
	settings := map[string]any{
		"general": map[string]any{
			"defaultApprovalMode": "plan",
			"plan": map[string]any{
				"enabled": true,
			},
		},
		"experimental": map[string]any{
			"dynamicModelConfiguration": true,
		},
		"modelConfigs": map[string]any{
			"customAliases": map[string]any{
				geminiEffortModelAlias: map[string]any{
					"modelConfig": map[string]any{
						"model": model,
						"generateContentConfig": map[string]any{
							"thinkingConfig": map[string]any{
								"thinkingLevel": thinkingLevel,
							},
						},
					},
				},
			},
		},
		"mcp": map[string]any{
			"excluded": []string{"*"},
		},
		"security": map[string]any{
			"disableAlwaysAllow": true,
		},
	}
	body, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return "", fmt.Errorf("marshal gemini effort settings: %w", err)
	}
	body = append(body, '\n')
	file, err := os.CreateTemp("", "cerberus-gemini-settings-*.json")
	if err != nil {
		return "", fmt.Errorf("create gemini effort settings: %w", err)
	}
	path := file.Name()
	if _, err := file.Write(body); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
		return "", fmt.Errorf("write gemini effort settings: %w", err)
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return "", fmt.Errorf("close gemini effort settings: %w", err)
	}
	return path, nil
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

func withGeminiToolNameDirective(system []byte) []byte {
	if bytes.Contains(system, []byte(geminiToolNameDirective)) {
		return system
	}
	if len(bytes.TrimSpace(system)) == 0 {
		return []byte(geminiToolNameDirective)
	}
	return bytes.Join([][]byte{system, []byte(geminiToolNameDirective)}, []byte("\n\n"))
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

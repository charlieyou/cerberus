package generate

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"sync"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/prompts"
)

// Options configures one generator run.
type Options struct {
	OutputDir     string
	Type          string
	Mode          string
	PromptFile    string
	Prompt        string
	Focus         string
	SkipInterview bool

	Root      string
	Providers []string
	Stderr    io.Writer
}

type provider struct {
	name  string
	model string
}

var providerRunner = runProvider

// Run fans out to the default provider CLIs and writes one output set per provider.
func Run(ctx context.Context, opts Options) error {
	if opts.OutputDir == "" {
		return fmt.Errorf("output directory is required")
	}
	if opts.Type == "" {
		return fmt.Errorf("type is required")
	}
	prompt := []byte(opts.Prompt)
	if len(prompt) == 0 {
		if opts.PromptFile == "" {
			return fmt.Errorf("prompt is required")
		}
		var err error
		prompt, err = os.ReadFile(opts.PromptFile)
		if err != nil {
			return fmt.Errorf("read prompt file %s: %w", opts.PromptFile, err)
		}
	}
	root, err := resolveRoot(opts.Root)
	if err != nil {
		return err
	}
	providers := providersFor(opts.Providers)
	results := make(chan providerResult, len(providers))
	var wg sync.WaitGroup
	for _, provider := range providers {
		provider := provider
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- runGeneratorProvider(ctx, root, opts, provider, prompt)
		}()
	}
	wg.Wait()
	close(results)

	var succeeded []string
	var failed []string
	var joined error
	for result := range results {
		if result.err != nil {
			failed = append(failed, result.provider+".failed")
			joined = errors.Join(joined, result.err)
			continue
		}
		succeeded = append(succeeded, result.provider)
	}
	sort.Strings(succeeded)
	sort.Strings(failed)
	if len(failed) > 0 {
		fmt.Fprintf(stderrFor(opts), "cerberus generate: %d provider%s succeeded, %d failed (%s)\n", len(succeeded), plural(len(succeeded)), len(failed), joinProviderMarkers(failed))
	}
	if len(failed) == len(providers) {
		return fmt.Errorf("cerberus generate: all providers failed: %w", joined)
	}
	return nil
}

func providersFor(names []string) []provider {
	if len(names) == 0 {
		names = []string{"claude", "codex", "gemini"}
	}
	providers := make([]provider, 0, len(names))
	for _, name := range names {
		model, _ := config.DefaultModelForProvider(name)
		providers = append(providers, provider{name: name, model: model})
	}
	return providers
}

type providerResult struct {
	provider string
	err      error
}

func runGeneratorProvider(ctx context.Context, root string, opts Options, provider provider, prompt []byte) (result providerResult) {
	startedAt := time.Now().UTC()
	result = providerResult{provider: provider.name}
	stats := Stats{
		StartedAt: startedAt,
	}
	defer func() {
		if recovered := recover(); recovered != nil {
			result.err = fmt.Errorf("generator %s panic: %v", provider.name, recovered)
			stats.ExitCode = 1
			stats.ErrorMessage = result.err.Error()
			endedAt := time.Now().UTC()
			stats.EndedAt = endedAt
			stats.TimeToFinishMs = endedAt.Sub(startedAt).Milliseconds()
			if err := writeFailureOutput(opts.OutputDir, provider.name, stats, result.err); err != nil {
				result.err = errors.Join(result.err, err)
			}
		}
	}()

	system, err := prompts.ComposeGeneratorWithOptionsFromRoot(root, provider.name, opts.Type, opts.Mode, opts.SkipInterview)
	if err != nil {
		return failProvider(opts.OutputDir, provider.name, startedAt, err, exitCodeFromError(err))
	}
	draft, _, err := providerRunner(ctx, root, provider.name, provider.model, system, string(prompt))
	if err != nil {
		return failProvider(opts.OutputDir, provider.name, startedAt, err, exitCodeFromError(err))
	}
	if len(bytes.TrimSpace(draft)) == 0 {
		err := fmt.Errorf("generator %s produced empty stdout", provider.name)
		return failProvider(opts.OutputDir, provider.name, startedAt, err, 1)
	}
	rawJSON, parsedStats, err := ParseProviderJSON(provider.name, draft)
	if err != nil {
		return failProvider(opts.OutputDir, provider.name, startedAt, err, 1)
	}
	stats.Tokens = parsedStats.Tokens
	stats.CostUSD = parsedStats.CostUSD
	stats.ExitCode = 0
	endedAt := time.Now().UTC()
	stats.EndedAt = endedAt
	stats.TimeToFinishMs = endedAt.Sub(startedAt).Milliseconds()
	if err := WriteSuccess(opts.OutputDir, provider.name, draft, rawJSON); err != nil {
		return failProvider(opts.OutputDir, provider.name, startedAt, err, 1)
	}
	if err := WriteStats(opts.OutputDir, provider.name, stats); err != nil {
		return failProvider(opts.OutputDir, provider.name, startedAt, err, 1)
	}
	return result
}

func failProvider(outputDir, provider string, startedAt time.Time, err error, exitCode int) providerResult {
	if exitCode == 0 {
		exitCode = 1
	}
	endedAt := time.Now().UTC()
	stats := Stats{
		TimeToFinishMs: endedAt.Sub(startedAt).Milliseconds(),
		ExitCode:       exitCode,
		ErrorMessage:   err.Error(),
		StartedAt:      startedAt,
		EndedAt:        endedAt,
	}
	if writeErr := writeFailureOutput(outputDir, provider, stats, err); writeErr != nil {
		err = errors.Join(err, writeErr)
	}
	return providerResult{provider: provider, err: err}
}

func writeFailureOutput(outputDir, provider string, stats Stats, providerErr error) error {
	var err error
	if writeErr := WriteFailure(outputDir, provider, stats.ExitCode, providerErr.Error()); writeErr != nil {
		err = errors.Join(err, writeErr)
	}
	if writeErr := WriteStats(outputDir, provider, stats); writeErr != nil {
		err = errors.Join(err, writeErr)
	}
	return err
}

func exitCodeFromError(err error) int {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return 1
}

func stderrFor(opts Options) io.Writer {
	if opts.Stderr != nil {
		return opts.Stderr
	}
	return os.Stderr
}

func plural(count int) string {
	if count == 1 {
		return ""
	}
	return "s"
}

func joinProviderMarkers(markers []string) string {
	if len(markers) == 0 {
		return ""
	}
	joined := markers[0]
	for _, marker := range markers[1:] {
		joined += ", " + marker
	}
	return joined
}

func resolveRoot(root string) (string, error) {
	if root != "" {
		return root, nil
	}
	root, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("resolve current directory: %w", err)
	}
	return root, nil
}

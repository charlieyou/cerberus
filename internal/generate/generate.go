package generate

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/charlieyou/cerberus/internal/prompts"
)

// ProviderSpec is one resolved generator drafter: the CLI provider to invoke,
// the model to pass it, and the output subdirectory label. Labels must be
// unique within a run so two instances of the same provider (for example two
// codex models) write to distinct directories.
type ProviderSpec struct {
	Provider string
	Model    string
	Effort   string
	Label    string
}

// Options configures one generator run.
type Options struct {
	OutputDir     string
	Type          string
	Mode          string
	PromptFile    string
	Prompt        string
	Focus         string
	SkipInterview bool

	Root string
	// Panel is the config-resolved drafter panel. It supports multiple instances
	// of the same provider via distinct labels.
	Panel  []ProviderSpec
	Stdout io.Writer
	Stderr io.Writer
}

type provider struct {
	name   string
	model  string
	effort string
	// label is the output subdirectory name; equals name for single-instance
	// providers and disambiguates same-provider instances (e.g. codex-2).
	label string
	// instanceID is the reviewer/replay identity in <provider>#<n> form (e.g.
	// codex#1, codex#2). Single instances stay #1 for fixture compatibility.
	instanceID string
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
	providers := resolvePanel(opts.Panel)
	if len(providers) == 0 {
		return fmt.Errorf("model panel is required")
	}
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
	succeededLabels := make(map[string]bool)
	for result := range results {
		if result.err != nil {
			failed = append(failed, result.provider+".failed")
			joined = errors.Join(joined, result.err)
			continue
		}
		succeeded = append(succeeded, result.provider)
		succeededLabels[result.provider] = true
	}
	sort.Strings(succeeded)
	sort.Strings(failed)
	// Print the draft.md path for each successful drafter, in panel order, so
	// callers (the create-* skills) can discover outputs without hard-coding
	// provider directories.
	for _, p := range providers {
		if succeededLabels[p.label] {
			fmt.Fprintln(stdoutFor(opts), filepath.Join(opts.OutputDir, p.label, "draft.md"))
		}
	}
	if len(failed) > 0 {
		fmt.Fprintf(stderrFor(opts), "cerberus generate: %d provider%s succeeded, %d failed (%s)\n", len(succeeded), plural(len(succeeded)), len(failed), joinProviderMarkers(failed))
	}
	if len(failed) == len(providers) {
		return fmt.Errorf("cerberus generate: all providers failed: %w", joined)
	}
	return nil
}

func resolvePanel(panel []ProviderSpec) []provider {
	providers := make([]provider, 0, len(panel))
	for _, spec := range panel {
		label := spec.Label
		if label == "" {
			label = spec.Provider
		}
		providers = append(providers, provider{name: spec.Provider, model: spec.Model, effort: spec.Effort, label: label})
	}
	// Assign per-provider instance IDs (codex#1, codex#2). Single instances are
	// #1, matching reviewer replay fixtures keyed by <hash>:<provider>#1.
	counts := make(map[string]int)
	for i := range providers {
		counts[providers[i].name]++
		providers[i].instanceID = fmt.Sprintf("%s#%d", providers[i].name, counts[providers[i].name])
	}
	return providers
}

type providerResult struct {
	provider string
	err      error
}

func runGeneratorProvider(ctx context.Context, root string, opts Options, provider provider, prompt []byte) (result providerResult) {
	// name keys the CLI invocation, prompt composition, and output parsing
	// (all provider-type specific); label keys the output directory and result
	// marker (unique per instance).
	name := provider.name
	label := provider.label
	startedAt := time.Now().UTC()
	result = providerResult{provider: label}
	stats := Stats{
		StartedAt: startedAt,
	}
	defer func() {
		if recovered := recover(); recovered != nil {
			result.err = fmt.Errorf("generator %s panic: %v", name, recovered)
			stats.ExitCode = 1
			stats.ErrorMessage = result.err.Error()
			endedAt := time.Now().UTC()
			stats.EndedAt = endedAt
			stats.TimeToFinishMs = endedAt.Sub(startedAt).Milliseconds()
			if err := writeFailureOutput(opts.OutputDir, label, stats, result.err); err != nil {
				result.err = errors.Join(result.err, err)
			}
		}
	}()

	system, err := prompts.ComposeGeneratorWithOptionsFromRoot(root, name, opts.Type, opts.Mode, opts.SkipInterview)
	if err != nil {
		return failProvider(opts.OutputDir, label, startedAt, err, exitCodeFromError(err))
	}
	draft, _, err := providerRunner(ctx, root, name, provider.model, provider.effort, opts.Mode, provider.instanceID, system, string(prompt))
	if err != nil {
		return failProvider(opts.OutputDir, label, startedAt, err, exitCodeFromError(err))
	}
	if len(bytes.TrimSpace(draft)) == 0 {
		err := fmt.Errorf("generator %s produced empty stdout", name)
		return failProvider(opts.OutputDir, label, startedAt, err, 1)
	}
	rawJSON, parsedStats, err := ParseProviderJSON(name, draft)
	if err != nil {
		return failProvider(opts.OutputDir, label, startedAt, err, 1)
	}
	draftText, err := extractDraftText(name, draft)
	if err != nil {
		return failProvider(opts.OutputDir, label, startedAt, err, 1)
	}
	if len(bytes.TrimSpace(draftText)) == 0 {
		err := fmt.Errorf("generator %s produced empty draft", name)
		return failProvider(opts.OutputDir, label, startedAt, err, 1)
	}
	stats.Tokens = parsedStats.Tokens
	stats.CostUSD = parsedStats.CostUSD
	stats.ExitCode = 0
	endedAt := time.Now().UTC()
	stats.EndedAt = endedAt
	stats.TimeToFinishMs = endedAt.Sub(startedAt).Milliseconds()
	if err := WriteSuccess(opts.OutputDir, label, draftText, rawJSON); err != nil {
		return failProvider(opts.OutputDir, label, startedAt, err, 1)
	}
	if err := WriteStats(opts.OutputDir, label, stats); err != nil {
		return failProvider(opts.OutputDir, label, startedAt, err, 1)
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

func stdoutFor(opts Options) io.Writer {
	if opts.Stdout != nil {
		return opts.Stdout
	}
	return io.Discard
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

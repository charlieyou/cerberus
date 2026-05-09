package generate

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

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
}

type provider struct {
	name  string
	model string
}

var providerRunner = runProvider

// Run fans out to the default provider CLIs and writes one draft.md per provider.
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
	errs := make(chan error, len(providers))
	var wg sync.WaitGroup
	for _, provider := range providers {
		provider := provider
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := runGeneratorProvider(ctx, root, opts, provider, prompt); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)

	var joined error
	for err := range errs {
		joined = errors.Join(joined, err)
	}
	return joined
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

func runGeneratorProvider(ctx context.Context, root string, opts Options, provider provider, prompt []byte) error {
	system, err := prompts.ComposeGeneratorWithOptionsFromRoot(root, provider.name, opts.Type, opts.Mode, opts.SkipInterview)
	if err != nil {
		return err
	}
	draft, _, err := providerRunner(ctx, root, provider.name, provider.model, system, string(prompt))
	if err != nil {
		return err
	}
	if len(bytes.TrimSpace(draft)) == 0 {
		return fmt.Errorf("generator %s produced empty stdout", provider.name)
	}
	outputDir := filepath.Join(opts.OutputDir, provider.name)
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		return fmt.Errorf("create %s draft directory: %w", provider.name, err)
	}
	if err := os.WriteFile(filepath.Join(outputDir, "draft.md"), draft, 0o644); err != nil {
		return fmt.Errorf("write %s draft: %w", provider.name, err)
	}
	return nil
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

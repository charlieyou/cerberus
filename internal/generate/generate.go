package generate

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/charlieyou/cerberus/internal/config"
)

// Options configures one generator run.
type Options struct {
	OutputDir  string
	Type       string
	Mode       string
	PromptFile string

	Root      string
	Providers []string
}

type provider struct {
	name  string
	model string
}

// Run fans out to the default provider CLIs and writes one draft.md per provider.
func Run(ctx context.Context, opts Options) error {
	if opts.OutputDir == "" {
		return fmt.Errorf("output directory is required")
	}
	if opts.Type == "" {
		return fmt.Errorf("type is required")
	}
	if opts.PromptFile == "" {
		return fmt.Errorf("prompt file is required")
	}

	prompt, err := os.ReadFile(opts.PromptFile)
	if err != nil {
		return fmt.Errorf("read prompt file: %w", err)
	}
	root, err := resolveRoot(opts.Root)
	if err != nil {
		return err
	}
	for _, provider := range providersFor(opts.Providers) {
		draft, err := runProvider(ctx, root, opts, provider, prompt)
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

func runProvider(ctx context.Context, root string, opts Options, provider provider, prompt []byte) ([]byte, error) {
	system := []byte("Cerberus generator type: " + opts.Type + ".")
	if opts.Mode != "" {
		system = bytes.Join([][]byte{system, []byte("Cerberus generate mode: " + opts.Mode + ".")}, []byte("\n\n"))
	}
	command, err := providerCommand(ctx, root, provider, system)
	if err != nil {
		return nil, err
	}
	command.Stdin = bytes.NewReader(prompt)

	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		return nil, fmt.Errorf("generator %s failed: %w; stderr: %s", provider.name, err, stderr.String())
	}
	return stdout.Bytes(), nil
}

func providerCommand(ctx context.Context, root string, provider provider, system []byte) (*exec.Cmd, error) {
	if bytes.Contains([]byte(provider.name), []byte{0}) || bytes.Contains([]byte(provider.model), []byte{0}) || bytes.Contains(system, []byte{0}) {
		return nil, fmt.Errorf("generator command contains NUL byte")
	}
	args := []string{}
	switch provider.name {
	case "claude":
		args = []string{"--print", "--output-format", "text", "--model", provider.model, "--append-system-prompt", string(system)}
	case "codex":
		args = []string{"--model", provider.model, "--append-system-prompt", string(system)}
	case "gemini":
		policyPath := filepath.Join(root, "config", "gemini-readonly-policy.toml")
		if _, err := os.Stat(policyPath); err != nil {
			return nil, fmt.Errorf("gemini policy file %s is required: %w", policyPath, err)
		}
		args = []string{"--model", provider.model, "--append-system-prompt", string(system), "--policy-file", policyPath}
	default:
		return nil, fmt.Errorf("unsupported generator provider %q", provider.name)
	}
	return exec.CommandContext(ctx, provider.name, args...), nil
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

package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/generate"
	"github.com/charlieyou/cerberus/internal/roster"
)

const generateUsage = "usage: cerberus generate <output-dir> --type <create-plan|create-spec> [--mode <config-mode>] [--prompt-file <path>|--focus <text>|prompt text...]"

type generateUsageError struct {
	err error
}

func (e generateUsageError) Error() string {
	return e.err.Error()
}

func runGenerate(args []string, stdout, stderr io.Writer) int {
	opts, err := parseGenerateFlags(args, stderr)
	if err != nil {
		fmt.Fprintln(stderr, err)
		var usageErr generateUsageError
		if errors.As(err, &usageErr) {
			fmt.Fprintln(stderr, generateUsage)
			return 2
		}
		return 1
	}
	opts.Root = config.Resolve().Root
	opts.Stdout = stdout
	opts.Stderr = stderr
	panel, mode, err := generatorPanel(opts.Mode)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	opts.Panel = panel
	opts.Mode = mode
	if err := generate.Run(context.Background(), opts); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}

// generatorPanel resolves the drafter panel for one config-defined mode.
func generatorPanel(mode string) ([]generate.ProviderSpec, string, error) {
	file, err := roster.LoadConfig("")
	if err != nil {
		return nil, "", err
	}
	if mode == "" && file != nil {
		mode = file.Defaults.Mode
	}
	if mode == "" {
		mode = "smart"
	}
	// Generators copy only provider/model/effort/label; skip review-only strategy and
	// persona file validation so a configured mode does not fail
	// generation when those files aren't reachable from the generator's cwd.
	slots, err := roster.ResolveWithOptions(file, roster.ResolveOptions{Mode: mode, SkipStrategyPersona: true})
	if err != nil {
		return nil, "", err
	}
	specs := make([]generate.ProviderSpec, 0, len(slots))
	for _, slot := range slots {
		label := slot.Provider
		if slot.InstanceIndex > 1 {
			label = fmt.Sprintf("%s-%d", slot.Provider, slot.InstanceIndex)
		}
		specs = append(specs, generate.ProviderSpec{
			Provider: slot.Provider,
			Model:    slot.Model,
			Effort:   slot.Effort,
			Label:    label,
		})
	}
	return specs, mode, nil
}

func parseGenerateFlags(args []string, _ io.Writer) (generate.Options, error) {
	var opts generate.Options
	if len(args) == 0 || args[0] == "" || args[0][0] == '-' {
		return generate.Options{}, usagef("generate requires an output directory")
	}
	opts.OutputDir = args[0]

	fs := flag.NewFlagSet("generate", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.Usage = func() {
		fmt.Fprintln(fs.Output(), generateUsage)
	}
	fs.StringVar(&opts.Type, "type", "", "generator type")
	fs.StringVar(&opts.Mode, "mode", "", "generator mode defined in config.yaml")
	fs.StringVar(&opts.PromptFile, "prompt-file", "", "prompt file")
	fs.StringVar(&opts.Focus, "focus", "", "focus text")
	fs.BoolVar(&opts.SkipInterview, "skip-interview", false, "skip interview prompt")
	if err := fs.Parse(args[1:]); err != nil {
		return generate.Options{}, usagef("%w", err)
	}
	modeSet := false
	fs.Visit(func(flag *flag.Flag) {
		if flag.Name == "mode" {
			modeSet = true
		}
	})
	if !validGenerateType(opts.Type) {
		return generate.Options{}, usagef("--type must be one of create-plan, create-spec")
	}
	if modeSet && strings.TrimSpace(opts.Mode) == "" {
		return generate.Options{}, usagef("--mode must not be empty")
	}
	if err := ensureGenerateOutputDir(opts.OutputDir); err != nil {
		return generate.Options{}, err
	}

	switch {
	case opts.PromptFile != "":
		prompt, err := os.ReadFile(opts.PromptFile)
		if err != nil {
			return generate.Options{}, fmt.Errorf("read prompt file %s: %w", opts.PromptFile, err)
		}
		opts.Prompt = string(prompt)
	case opts.Focus != "":
		opts.Prompt = opts.Focus
	case fs.NArg() > 0:
		opts.Prompt = strings.Join(fs.Args(), " ")
	default:
		return generate.Options{}, usagef("one of --prompt-file, --focus, or prompt text is required")
	}
	return opts, nil
}

func usagef(format string, args ...any) error {
	return generateUsageError{err: fmt.Errorf(format, args...)}
}

func validGenerateType(value string) bool {
	switch value {
	case "create-plan", "create-spec":
		return true
	default:
		return false
	}
}

func ensureGenerateOutputDir(path string) error {
	info, err := os.Stat(path)
	if err == nil {
		if !info.IsDir() {
			return fmt.Errorf("output directory %s exists and is not a directory", path)
		}
		return nil
	}
	if !os.IsNotExist(err) {
		return fmt.Errorf("stat output directory %s: %w", path, err)
	}
	if err := os.MkdirAll(path, 0o755); err != nil {
		return fmt.Errorf("create output directory %s: %w", path, err)
	}
	return nil
}

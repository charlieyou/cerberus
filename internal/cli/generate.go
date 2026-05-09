package cli

import (
	"context"
	"flag"
	"fmt"
	"io"

	"github.com/charlieyou/cerberus/internal/generate"
)

func runGenerate(args []string, stdout, stderr io.Writer) int {
	opts, err := parseGenerateFlags(args, stderr)
	if err != nil {
		fmt.Fprintln(stderr, err)
		fmt.Fprintln(stderr, "usage: cerberus generate <output-dir> --type <create-plan|create-spec|healthcheck|architecture-review> --mode <mode> --prompt-file <path>")
		return 2
	}
	if err := generate.Run(context.Background(), opts); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}

func parseGenerateFlags(args []string, stderr io.Writer) (generate.Options, error) {
	var opts generate.Options
	if len(args) == 0 || args[0] == "" || args[0][0] == '-' {
		return generate.Options{}, fmt.Errorf("generate requires exactly one output directory")
	}
	opts.OutputDir = args[0]

	fs := flag.NewFlagSet("generate", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&opts.Type, "type", "", "generator type")
	fs.StringVar(&opts.Mode, "mode", "", "generator mode")
	fs.StringVar(&opts.PromptFile, "prompt-file", "", "prompt file")
	if err := fs.Parse(args[1:]); err != nil {
		return generate.Options{}, err
	}
	if fs.NArg() != 0 {
		return generate.Options{}, fmt.Errorf("generate accepts one output directory")
	}
	if !validGenerateType(opts.Type) {
		return generate.Options{}, fmt.Errorf("--type must be one of create-plan, create-spec, healthcheck, architecture-review")
	}
	if opts.PromptFile == "" {
		return generate.Options{}, fmt.Errorf("--prompt-file is required")
	}
	return opts, nil
}

func validGenerateType(value string) bool {
	switch value {
	case "create-plan", "create-spec", "healthcheck", "architecture-review":
		return true
	default:
		return false
	}
}

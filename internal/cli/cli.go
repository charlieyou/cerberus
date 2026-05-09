package cli

import (
	"flag"
	"fmt"
	"io"
	"os"
)

const usage = `usage: cerberus <subcommand> [options]

Subcommands:
  check    report the active review gate status
`

// Run dispatches the cerberus CLI and returns a process exit code.
func Run(args []string) int {
	return run(args, os.Stdout, os.Stderr)
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stderr)
		return 2
	}

	switch args[0] {
	case "check":
		return runCheck(args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown subcommand %q\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func runCheck(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	fmt.Fprintln(stdout, "no active review")
	return 0
}

func printUsage(w io.Writer) {
	fmt.Fprint(w, usage)
}

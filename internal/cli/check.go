package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/charlieyou/cerberus/internal/state"
)

func runCheck(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	path, ok, err := gateStatePath()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if !ok {
		fmt.Fprintln(stdout, "no active review")
		return 0
	}
	gate, err := state.ReadGateState(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			fmt.Fprintln(stdout, "no active review")
			return 0
		}
		fmt.Fprintln(stderr, err)
		return 1
	}
	fmt.Fprintf(stdout, "%s\n", gate.Status)
	return 0
}

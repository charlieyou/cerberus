package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/charlieyou/cerberus/internal/state"
)

func runStatus(args []string, stdout, stderr io.Writer) int {
	var jsonOut bool
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.BoolVar(&jsonOut, "json", false, "print JSON")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	path, ok, err := gateStatePath()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if !ok {
		return printNoActiveStatus(stdout, jsonOut)
	}
	gate, err := state.ReadGateState(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return printNoActiveStatus(stdout, jsonOut)
		}
		fmt.Fprintln(stderr, err)
		return 1
	}
	if jsonOut {
		data, err := json.MarshalIndent(gate, "", "  ")
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		fmt.Fprintln(stdout, string(data))
		return 0
	}
	fmt.Fprintf(stdout, "status: %s\n", gate.Status)
	if gate.Verdict != nil {
		fmt.Fprintf(stdout, "verdict: %s\n", *gate.Verdict)
	}
	return 0
}

func printNoActiveStatus(stdout io.Writer, jsonOut bool) int {
	if jsonOut {
		fmt.Fprintln(stdout, `{"status":"no_active_gate"}`)
		return 0
	}
	fmt.Fprintln(stdout, "no active review")
	return 0
}

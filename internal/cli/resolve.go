package cli

import (
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/charlieyou/cerberus/internal/state"
)

func runResolve(args []string, stdout, stderr io.Writer) int {
	var reason string
	fs := flag.NewFlagSet("resolve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&reason, "reason", "", "resolution reason")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	_ = reason

	path, ok, err := gateStatePath()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if !ok {
		fmt.Fprintln(stderr, "no active review")
		return 1
	}
	gate, err := state.ReadGateState(path)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	verdict := state.VerdictRequiresDecision
	if gate.Verdict != nil {
		verdict = *gate.Verdict
	}
	state.MarkResolved(gate, verdict, time.Now().UTC())
	if err := state.WriteGateState(path, gate); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	fmt.Fprintln(stdout, "resolved")
	return 0
}

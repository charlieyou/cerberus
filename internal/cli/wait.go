package cli

import (
	"flag"
	"fmt"
	"io"
	"time"

	"github.com/charlieyou/cerberus/internal/hook"
)

func runWait(args []string, stdout, stderr io.Writer) int {
	var jsonOut bool
	var finalize bool
	fs := flag.NewFlagSet("wait", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.BoolVar(&jsonOut, "json", false, "print JSON")
	fs.BoolVar(&finalize, "finalize", false, "reserved compatibility flag")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	_ = finalize

	path, ok, err := gateStatePath()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if !ok {
		return printNoActiveStatus(stdout, jsonOut)
	}
	if err := hook.PollGateState(path, hook.PollIntervalSeconds*time.Second, hook.MaxWaitSeconds*time.Second); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return runStatus(boolFlagArgs(jsonOut), stdout, stderr)
}

func boolFlagArgs(jsonOut bool) []string {
	if jsonOut {
		return []string{"--json"}
	}
	return nil
}

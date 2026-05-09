package cli

import (
	"flag"
	"fmt"
	"io"
)

func runArtifactPath(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("artifact-path", flag.ContinueOnError)
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	runRoot, ok, err := activeRunRoot()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if !ok {
		fmt.Fprintln(stderr, "CERBERUS_RUN_KEY or CERBERUS_SESSION_ID is required")
		return 1
	}
	fmt.Fprintln(stdout, artifactPath(runRoot))
	return 0
}

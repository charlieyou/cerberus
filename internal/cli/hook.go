package cli

import (
	"fmt"
	"io"
	"os"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/hook"
)

func runHook(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: cerberus hook <claude-stop|claude-session-start>")
		return 2
	}
	payload, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	env := config.Resolve()
	switch args[0] {
	case "claude-stop":
		err = hook.HandleClaudeStop(payload, env)
	case "claude-session-start":
		err = hook.HandleClaudeSessionStart(payload, env)
	default:
		fmt.Fprintf(stderr, "unknown hook subcommand %q\n", args[0])
		return 2
	}
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	_ = stdout
	return 0
}

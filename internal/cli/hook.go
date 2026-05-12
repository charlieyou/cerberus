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
		fmt.Fprintln(stderr, "usage: cerberus hook <claude-stop|claude-session-start|codex-stop|codex-session-start|codex-prompt-submit>")
		return 2
	}
	payload, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	env := config.Resolve()
	response := ""
	claudeStopFeedback := false
	switch args[0] {
	case "claude-stop":
		response, err = hook.HandleClaudeStopResponse(payload, env)
		claudeStopFeedback = response != ""
	case "claude-session-start":
		err = hook.HandleClaudeSessionStart(payload, env)
	case "codex-stop":
		response, err = hook.HandleCodexStopResponse(payload, env)
	case "codex-session-start":
		err = hook.HandleCodexSessionStart(payload, env)
	case "codex-prompt-submit":
		err = hook.HandleCodexPromptSubmit(payload, env)
	default:
		fmt.Fprintf(stderr, "unknown hook subcommand %q\n", args[0])
		return 2
	}
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if claudeStopFeedback {
		// Claude Stop hooks feed exit-code-2 stderr back to the agent as
		// "Stop hook feedback". JSON decision/reason output is treated as hook
		// control metadata and is not surfaced as review instructions here.
		fmt.Fprintln(stderr, response)
		return 2
	}
	if response != "" {
		fmt.Fprint(stdout, response)
	}
	return 0
}

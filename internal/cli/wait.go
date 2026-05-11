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
	var timeoutSeconds int
	var pollIntervalSeconds int
	var sessionKey string
	var sessionID string
	var transcriptPath string
	fs := flag.NewFlagSet("wait", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.BoolVar(&jsonOut, "json", false, "print JSON")
	fs.BoolVar(&finalize, "finalize", false, "reserved compatibility flag")
	fs.IntVar(&timeoutSeconds, "timeout", int(hook.MaxWaitSeconds), "maximum seconds to wait")
	fs.IntVar(&pollIntervalSeconds, "poll-interval", int(hook.PollIntervalSeconds), "poll interval in seconds")
	fs.StringVar(&sessionKey, "session-key", "", "run key to inspect")
	fs.StringVar(&sessionID, "session-id", "", "session id to inspect")
	fs.StringVar(&transcriptPath, "transcript-path", "", "transcript path for compatibility")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	_ = finalize
	if timeoutSeconds < 0 {
		fmt.Fprintln(stderr, "--timeout must be >= 0")
		return 2
	}
	if pollIntervalSeconds <= 0 {
		fmt.Fprintln(stderr, "--poll-interval must be > 0")
		return 2
	}

	env := envWithRunOverrides(sessionKey, sessionID, transcriptPath)
	path, ok, err := gateStatePathForEnv(env)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if !ok {
		return printNoActiveStatus(stdout, jsonOut)
	}
	if err := hook.PollGateState(path, time.Duration(pollIntervalSeconds)*time.Second, time.Duration(timeoutSeconds)*time.Second); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return runStatus(statusArgs(jsonOut, sessionKey, sessionID, transcriptPath), stdout, stderr)
}

func statusArgs(jsonOut bool, sessionKey, sessionID, transcriptPath string) []string {
	var args []string
	if jsonOut {
		args = append(args, "--json")
	}
	if sessionKey != "" {
		args = append(args, "--session-key", sessionKey)
	}
	if sessionID != "" {
		args = append(args, "--session-id", sessionID)
	}
	if transcriptPath != "" {
		args = append(args, "--transcript-path", transcriptPath)
	}
	return args
}

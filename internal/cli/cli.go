package cli

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/host"
	"github.com/charlieyou/cerberus/internal/state"
)

const usage = `usage: cerberus <subcommand> [options]

Subcommands:
  spawn-code-review  run a single-pass code review
  wait               wait for the active review gate to resolve
  resolve            mark the active review gate resolved
  status             report the active review gate status
  check              report the active review gate status
  artifact-path      print the run artifact path
  author-context     set or clear reviewer author context
  hook               run a host hook subcommand
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
	case "spawn-code-review":
		return runSpawnCodeReview(args[1:], stdout, stderr)
	case "wait":
		return runWait(args[1:], stdout, stderr)
	case "resolve":
		return runResolve(args[1:], stdout, stderr)
	case "status":
		return runStatus(args[1:], stdout, stderr)
	case "check":
		return runCheck(args[1:], stdout, stderr)
	case "artifact-path":
		return runArtifactPath(args[1:], stdout, stderr)
	case "author-context":
		return runAuthorContext(args[1:], stdout, stderr)
	case "hook":
		return runHook(args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown subcommand %q\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func printUsage(w io.Writer) {
	fmt.Fprint(w, usage)
}

func activeRunRoot() (string, bool, error) {
	env := config.Resolve()
	if env.Host == "" {
		env.Host = "generic"
	}
	if env.RunKey == "" {
		env.RunKey = env.SessionID
	}
	if env.RunKey == "" {
		return "", false, nil
	}
	adapter, err := host.NewFromEnv(env)
	if err != nil {
		return "", false, err
	}
	if env.ProjectKey == "" {
		projectKey, err := adapter.ProjectKey(env)
		if err != nil {
			return "", false, err
		}
		env.ProjectKey = projectKey
	}
	if env.StateRoot == "" {
		stateRoot, err := adapter.StateRoot(env)
		if err != nil {
			return "", false, err
		}
		env.StateRoot = stateRoot
	}
	return state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey), true, nil
}

func gateStatePath() (string, bool, error) {
	runRoot, ok, err := activeRunRoot()
	if err != nil || !ok {
		return "", ok, err
	}
	return state.GateStatePath(runRoot), true, nil
}

func artifactPath(runRoot string) string {
	return filepath.Join(runRoot, "artifact.txt")
}

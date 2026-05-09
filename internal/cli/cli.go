package cli

import (
	"errors"
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
  spawn-plan-review  run a plan review
  spawn-spec-review  run a spec review
  spawn-ask          ask the review panel a question
  spawn-epic-verify  verify an epic
  wait               wait for the active review gate to resolve
  resolve            mark the active review gate resolved
  status             report the active review gate status
  check              report the active review gate status
  artifact-path      print the run artifact path
  author-context     set or clear reviewer author context
  hook               run a host hook subcommand
  generate           generate multi-model drafts
`

const ExitCodePreflight = 6

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
	case "spawn-code-review", "spawn-plan-review", "spawn-spec-review", "spawn-ask", "spawn-epic-verify":
		return runSpawnCodeReview(args[1:], stdout, stderr)
	case "run-single-pass":
		return runSinglePassRuntime(args[1:], stdout, stderr)
	case "run-debate":
		return runDebateRuntime(args[1:], stdout, stderr)
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
	case "generate":
		return runGenerate(args[1:], stdout, stderr)
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
		if env.Host == "generic" && env.RunKey == "" {
			return "", false, nil
		}
		stateRoot, err := adapter.StateRoot(env)
		if err != nil {
			return "", false, err
		}
		env.StateRoot = stateRoot
	}
	if env.RunKey == "" {
		cache, err := state.ReadSessionCache(state.SessionCachePath(env.StateRoot, env.ProjectKey))
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return "", false, nil
			}
			return "", false, err
		}
		env.RunKey = cache.RunKey
		env.SessionID = cache.SessionID
		env.TranscriptPath = cache.TranscriptPath
	}
	if env.RunKey == "" {
		return "", false, nil
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

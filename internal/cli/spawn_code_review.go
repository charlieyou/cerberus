package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/roster"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

type repeatString []string

func (values *repeatString) String() string {
	return strings.Join(*values, ",")
}

func (values *repeatString) Set(value string) error {
	*values = append(*values, value)
	return nil
}

func runSpawnCodeReview(args []string, stdout, stderr io.Writer) int {
	return runSpawnReview(args, stdout, stderr, "code")
}

func runSpawnReview(args []string, stdout, stderr io.Writer, artifactType string) int {
	opts, err := parseSpawnCodeReviewFlags(normalizeReviewArgs(args, artifactType), stderr)
	if err != nil {
		recordSpawnPreflightFailure("flags", err)
		fmt.Fprintln(stderr, err)
		return 2
	}
	opts.artifactType = artifactType

	resolved, err := resolveReviewers(opts)
	if err != nil {
		recordSpawnPreflightFailure("roster", err)
		fmt.Fprintln(stderr, err)
		return exitCodeForError(err, 2)
	}
	prompt, err := prepareReviewPrompt(&opts)
	if err != nil {
		recordSpawnPreflightFailure("prompt", err)
		fmt.Fprintln(stderr, err)
		return 1
	}
	if opts.debate {
		started, err := (orchestrator.Orchestrator{Env: config.Resolve()}).StartDebate(orchestrator.Params{
			Prompt:             prompt,
			ArtifactType:       opts.artifactType,
			ArtifactContent:    opts.artifactContent,
			ContextContent:     opts.contextContent,
			Reviewers:          resolved.reviewers,
			PostReviewer:       opts.postReviewSlot(),
			RosterDefaults:     resolved.defaults,
			Mode:               opts.mode,
			MaxRounds:          opts.explicitMaxRounds(),
			Consensus:          orchestrator.ConsensusMode(opts.consensus),
			FailurePriority:    opts.failurePriority,
			FailurePrioritySet: true,
			RosterID:           resolved.rosterID,
		})
		if err != nil {
			fmt.Fprintln(stderr, err)
			return exitCodeForError(err, 1)
		}
		if err := startDebateRuntime(started); err != nil {
			if resolveErr := orchestrator.ResolveDebateFailure(started, err); resolveErr != nil {
				fmt.Fprintf(stderr, "%v\nfailed to resolve gate after debate runtime launch error: %v\n", err, resolveErr)
			} else {
				fmt.Fprintln(stderr, err)
			}
			return 1
		}
		warnIfGenericHostNeedsManualWait(started, stderr)
		fmt.Fprintf(stdout, "review spawned (run key: %s)\n", started.Env.RunKey)
		return 0
	}

	params := orchestrator.Params{
		Prompt:             prompt,
		ArtifactType:       opts.artifactType,
		ArtifactContent:    opts.artifactContent,
		ContextContent:     opts.contextContent,
		Reviewers:          resolved.reviewers,
		PostReviewer:       opts.postReviewSlot(),
		RosterDefaults:     resolved.defaults,
		Mode:               opts.mode,
		MaxRounds:          opts.explicitMaxRounds(),
		Consensus:          orchestrator.ConsensusMode(opts.consensus),
		FailurePriority:    opts.failurePriority,
		FailurePrioritySet: true,
		RosterID:           resolved.rosterID,
	}
	started, err := orchestrator.StartSinglePass(config.Resolve(), params)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return exitCodeForError(err, 1)
	}
	if err := startReviewRuntime(started); err != nil {
		if resolveErr := orchestrator.ResolveSinglePassFailure(started, err); resolveErr != nil {
			fmt.Fprintf(stderr, "%v\nfailed to resolve gate after runtime launch error: %v\n", err, resolveErr)
		} else {
			fmt.Fprintln(stderr, err)
		}
		return 1
	}
	warnIfGenericHostNeedsManualWait(started, stderr)
	fmt.Fprintf(stdout, "review spawned (run key: %s)\n", started.Env.RunKey)
	return 0
}

func warnIfGenericHostNeedsManualWait(started *orchestrator.StartedRun, stderr io.Writer) {
	if started == nil || started.Env.Host != "generic" {
		return
	}
	fmt.Fprintf(stderr, "warning: CERBERUS_HOST=generic has no automatic Stop hook; run the same cerberus binary with `wait --json --session-key %q` and the same CERBERUS_STATE_ROOT and CERBERUS_PROJECT_KEY to wait for this gate\n", started.Env.RunKey)
}

func normalizeReviewArgs(args []string, artifactType string) []string {
	if artifactType != "epic-verify" {
		return args
	}
	knownValueFlags := map[string]bool{
		"-mode": true, "--mode": true, "-max-rounds": true, "--max-rounds": true,
		"-consensus": true, "--consensus": true, "-fail-priority": true, "--fail-priority": true,
		"-agents": true, "--agents": true,
		"-post-reviewer": true, "--post-reviewer": true,
		"-roster": true, "--roster": true, "-reviewer": true, "--reviewer": true,
		"-replace-slot": true, "--replace-slot": true, "-exclude": true, "--exclude": true,
		"-base": true, "--base": true, "-commit": true, "--commit": true,
		"-prompt-file": true, "--prompt-file": true, "-context-file": true, "--context-file": true,
	}
	knownBoolFlags := map[string]bool{"-uncommitted": true, "--uncommitted": true, "-debate": true, "--debate": true}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			return args
		}
		if !strings.HasPrefix(arg, "-") || arg == "-" {
			return args
		}
		name := arg
		if eq := strings.IndexByte(arg, '='); eq >= 0 {
			name = arg[:eq]
		}
		if knownValueFlags[name] {
			if !strings.Contains(arg, "=") {
				i++
			}
			continue
		}
		if knownBoolFlags[name] {
			continue
		}
		normalized := append([]string{}, args[:i]...)
		normalized = append(normalized, "--")
		normalized = append(normalized, args[i:]...)
		return normalized
	}
	return args
}

func recordSpawnPreflightFailure(stage string, err error) {
	_ = orchestrator.RecordPreflightFailure(config.Resolve(), stage, err)
}

func exitCodeForError(err error, fallback int) int {
	var coded interface {
		ExitCode() int
	}
	if errors.As(err, &coded) && coded.ExitCode() != 0 {
		return coded.ExitCode()
	}
	return fallback
}

var startReviewRuntime = startReviewRuntimeProcess
var startDebateRuntime = startDebateRuntimeProcess
var runtimeExecutable = os.Executable

func startReviewRuntimeProcess(started *orchestrator.StartedRun) error {
	requestPath := filepath.Join(started.RunRoot, "single-pass-request.json")
	return startRuntimeProcess(started, requestPath, "run-single-pass", "single-pass")
}

func startDebateRuntimeProcess(started *orchestrator.StartedRun) error {
	requestPath := filepath.Join(started.RunRoot, "debate-request.json")
	return startRuntimeProcess(started, requestPath, "run-debate", "debate")
}

func startRuntimeProcess(started *orchestrator.StartedRun, requestPath, subcommand, logPrefix string) error {
	data, err := json.MarshalIndent(started, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal %s request: %w", logPrefix, err)
	}
	data = append(data, '\n')
	if err := os.WriteFile(requestPath, data, 0o644); err != nil {
		return fmt.Errorf("write %s request: %w", logPrefix, err)
	}

	exe, err := runtimeExecutable()
	if err != nil {
		return fmt.Errorf("resolve executable: %w", err)
	}
	cmd := exec.Command(exe, subcommand, requestPath)
	stdoutPath := filepath.Join(started.RunRoot, logPrefix+".stdout.log")
	stderrPath := filepath.Join(started.RunRoot, logPrefix+".stderr.log")
	stdout, err := os.OpenFile(stdoutPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("open %s stdout log: %w", logPrefix, err)
	}
	defer stdout.Close()
	stderr, err := os.OpenFile(stderrPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("open %s stderr log: %w", logPrefix, err)
	}
	defer stderr.Close()
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := configureDetachedRuntime(cmd); err != nil {
		recordRuntimeEvent(started, telemetry.EventRuntimeLaunchFailed, map[string]any{
			"subcommand":   subcommand,
			"log_prefix":   logPrefix,
			"executable":   exe,
			"request_path": requestPath,
			"stdout_path":  stdoutPath,
			"stderr_path":  stderrPath,
			"error":        err.Error(),
		})
		return err
	}
	recordRuntimeEvent(started, telemetry.EventRuntimeLaunching, map[string]any{
		"subcommand":   subcommand,
		"log_prefix":   logPrefix,
		"executable":   exe,
		"request_path": requestPath,
		"stdout_path":  stdoutPath,
		"stderr_path":  stderrPath,
	})
	if err := cmd.Start(); err != nil {
		recordRuntimeEvent(started, telemetry.EventRuntimeLaunchFailed, map[string]any{
			"subcommand":   subcommand,
			"log_prefix":   logPrefix,
			"executable":   exe,
			"request_path": requestPath,
			"stdout_path":  stdoutPath,
			"stderr_path":  stderrPath,
			"error":        err.Error(),
		})
		return fmt.Errorf("start %s runtime: %w", logPrefix, err)
	}
	recordRuntimeEvent(started, telemetry.EventRuntimeLaunched, map[string]any{
		"subcommand":   subcommand,
		"log_prefix":   logPrefix,
		"executable":   exe,
		"request_path": requestPath,
		"stdout_path":  stdoutPath,
		"stderr_path":  stderrPath,
		"pid":          cmd.Process.Pid,
	})
	return cmd.Process.Release()
}

func runSinglePassRuntime(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: cerberus run-single-pass <request-path>")
		return 2
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	var started orchestrator.StartedRun
	if err := json.Unmarshal(data, &started); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	recordRuntimeEvent(&started, telemetry.EventRuntimeStarted, map[string]any{
		"subcommand":   "run-single-pass",
		"request_path": args[0],
		"pid":          os.Getpid(),
		"ppid":         os.Getppid(),
	})
	if err := orchestrator.CompleteSinglePass(context.Background(), &started, nil); err != nil {
		recordRuntimeEvent(&started, telemetry.EventRuntimeFailed, map[string]any{
			"subcommand":   "run-single-pass",
			"request_path": args[0],
			"pid":          os.Getpid(),
			"error":        err.Error(),
		})
		if resolveErr := orchestrator.ResolveSinglePassFailure(&started, err); resolveErr != nil {
			fmt.Fprintf(stderr, "%v\nfailed to resolve gate after runtime error: %v\n", err, resolveErr)
		} else {
			fmt.Fprintln(stderr, err)
		}
		return 1
	}
	recordRuntimeEvent(&started, telemetry.EventRuntimeCompleted, map[string]any{
		"subcommand":   "run-single-pass",
		"request_path": args[0],
		"pid":          os.Getpid(),
	})
	_ = stdout
	return 0
}

func runDebateRuntime(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		fmt.Fprintln(stderr, "usage: cerberus run-debate <request-path>")
		return 2
	}
	data, err := os.ReadFile(args[0])
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	var started orchestrator.StartedRun
	if err := json.Unmarshal(data, &started); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	recordRuntimeEvent(&started, telemetry.EventRuntimeStarted, map[string]any{
		"subcommand":   "run-debate",
		"request_path": args[0],
		"pid":          os.Getpid(),
		"ppid":         os.Getppid(),
	})
	if _, err := (orchestrator.Orchestrator{}).CompleteDebate(context.Background(), &started); err != nil {
		recordRuntimeEvent(&started, telemetry.EventRuntimeFailed, map[string]any{
			"subcommand":   "run-debate",
			"request_path": args[0],
			"pid":          os.Getpid(),
			"error":        err.Error(),
		})
		if resolveErr := orchestrator.ResolveDebateFailure(&started, err); resolveErr != nil {
			fmt.Fprintf(stderr, "%v\nfailed to resolve gate after debate runtime error: %v\n", err, resolveErr)
		} else {
			fmt.Fprintln(stderr, err)
		}
		return 1
	}
	recordRuntimeEvent(&started, telemetry.EventRuntimeCompleted, map[string]any{
		"subcommand":   "run-debate",
		"request_path": args[0],
		"pid":          os.Getpid(),
	})
	_ = stdout
	return 0
}

func recordRuntimeEvent(started *orchestrator.StartedRun, eventName string, payload map[string]any) {
	if started == nil || started.RunRoot == "" {
		return
	}
	if payload == nil {
		payload = map[string]any{}
	}
	payload["run_key"] = started.Env.RunKey
	payload["host"] = started.Env.Host
	payload["project_key"] = started.Env.ProjectKey
	payload["session_id"] = started.Env.SessionID
	_ = telemetry.WriteEvent(started.RunRoot, telemetry.Event{
		Event:     eventName,
		Timestamp: time.Now().UTC(),
		Payload:   payload,
	})
}

type spawnCodeReviewOptions struct {
	artifactType       string
	mode               string
	modeSet            bool
	maxRounds          int
	maxRoundsSet       bool
	consensus          string
	failurePriority    int
	failurePriorityRaw string
	agents             string
	roster             string
	reviewers          []string
	postReviewer       string
	replaceSlot        string
	excludes           []string
	uncommitted        bool
	base               string
	promptFile         string
	contextFile        string
	commits            []string
	debate             bool
	focus              string
	positionals        []string
	artifactContent    string
	contextContent     string
}

func (opts spawnCodeReviewOptions) postReviewSlot() orchestrator.ReviewerSlot {
	slot, _ := parsePostReviewer(opts.postReviewer)
	return slot
}

func (opts spawnCodeReviewOptions) explicitMaxRounds() int {
	if opts.maxRoundsSet {
		return opts.maxRounds
	}
	return 0
}

func parseSpawnCodeReviewFlags(args []string, stderr io.Writer) (spawnCodeReviewOptions, error) {
	var opts spawnCodeReviewOptions
	var reviewers repeatString
	var excludes repeatString
	var commits repeatString

	fs := flag.NewFlagSet("spawn-code-review", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&opts.mode, "mode", "smart", "review mode")
	fs.IntVar(&opts.maxRounds, "max-rounds", 3, "maximum review rounds")
	fs.StringVar(&opts.consensus, "consensus", "majority", "consensus mode")
	fs.StringVar(&opts.failurePriorityRaw, "fail-priority", "p1", "minimum finding priority that fails the gate (p0, p1, p2, or p3)")
	fs.StringVar(&opts.agents, "agents", "", "legacy comma-separated reviewer providers")
	fs.StringVar(&opts.roster, "roster", "", "roster name")
	fs.Var(&reviewers, "reviewer", "reviewer provider:model[:strategy]")
	fs.StringVar(&opts.postReviewer, "post-reviewer", "codex:"+config.DefaultCodexModel+":low", "post-review dedup agent provider:model[:effort]")
	fs.StringVar(&opts.replaceSlot, "replace-slot", "", "slot id to replace")
	fs.Var(&excludes, "exclude", "pathspec to exclude")
	fs.BoolVar(&opts.uncommitted, "uncommitted", false, "review uncommitted changes")
	fs.StringVar(&opts.base, "base", "", "base ref")
	fs.StringVar(&opts.promptFile, "prompt-file", "", "prompt file")
	fs.StringVar(&opts.contextFile, "context-file", "", "context file")
	fs.Var(&commits, "commit", "commit to review")
	fs.BoolVar(&opts.debate, "debate", false, "enable debate")
	if err := fs.Parse(args); err != nil {
		return opts, err
	}

	opts.reviewers = reviewers
	opts.excludes = excludes
	opts.commits = commits
	fs.Visit(func(flag *flag.Flag) {
		switch flag.Name {
		case "mode":
			opts.modeSet = true
		case "max-rounds":
			opts.maxRoundsSet = true
		}
	})
	if !opts.modeSet {
		opts.mode = ""
	}
	if !opts.maxRoundsSet {
		opts.maxRounds = 3
	}
	failurePriority, err := parseFailurePriority(opts.failurePriorityRaw)
	if err != nil {
		return opts, err
	}
	opts.failurePriority = failurePriority
	if len(opts.commits) > 0 {
		opts.commits, opts.focus = splitTrailingCommitArgs(opts.commits, fs.Args())
	} else {
		opts.positionals = fs.Args()
		opts.focus = strings.Join(fs.Args(), " ")
	}
	if err := validateSpawnCodeReviewOptions(opts); err != nil {
		return opts, err
	}
	return opts, nil
}

func parseFailurePriority(value string) (int, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	normalized = strings.TrimPrefix(normalized, "p")
	switch normalized {
	case "0":
		return 0, nil
	case "1":
		return 1, nil
	case "2":
		return 2, nil
	case "3":
		return 3, nil
	default:
		return 0, fmt.Errorf("--fail-priority must be p0, p1, p2, or p3")
	}
}

func splitTrailingCommitArgs(commits []string, args []string) ([]string, string) {
	for i, arg := range args {
		if !isCommitRevision(arg) {
			return append(commits, args[:i]...), strings.Join(args[i:], " ")
		}
	}
	return append(commits, args...), ""
}

func isCommitRevision(arg string) bool {
	if arg == "" || strings.ContainsAny(arg, " \t\r\n") || strings.HasPrefix(arg, "-") {
		return false
	}
	cmd := exec.Command("git", "rev-parse", "--verify", "--quiet", arg+"^{commit}")
	return cmd.Run() == nil
}

func validateSpawnCodeReviewOptions(opts spawnCodeReviewOptions) error {
	if opts.modeSet {
		switch opts.mode {
		case "fast", "smart", "max":
		default:
			return fmt.Errorf("--mode must be fast, smart, or max")
		}
	}
	if opts.maxRoundsSet && opts.maxRounds <= 0 {
		return fmt.Errorf("--max-rounds must be positive")
	}
	switch opts.consensus {
	case "majority", "all", "any":
	default:
		return fmt.Errorf("--consensus must be majority, all, or any")
	}
	if opts.agents != "" && (opts.roster != "" || len(opts.reviewers) > 0) {
		return fmt.Errorf("--agents is mutually exclusive with --roster and --reviewer")
	}
	for _, reviewer := range opts.reviewers {
		parts := strings.Split(reviewer, ":")
		if len(parts) < 2 || len(parts) > 3 {
			return fmt.Errorf("--reviewer must use provider:model[:strategy]")
		}
		for _, part := range parts {
			if part == "" {
				return fmt.Errorf("--reviewer must use provider:model[:strategy]")
			}
		}
	}
	if _, err := parsePostReviewer(opts.postReviewer); err != nil {
		return err
	}
	if opts.uncommitted && (opts.base != "" || len(opts.commits) > 0) {
		return fmt.Errorf("--uncommitted is mutually exclusive with --base and --commit")
	}
	if opts.base != "" && len(opts.commits) > 0 {
		return fmt.Errorf("--base is mutually exclusive with --commit")
	}
	return nil
}

func parsePostReviewer(value string) (orchestrator.ReviewerSlot, error) {
	if value == "" {
		value = "codex:" + config.DefaultCodexModel + ":low"
	}
	parts := strings.Split(value, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return orchestrator.ReviewerSlot{}, fmt.Errorf("--post-reviewer must use provider:model[:effort]")
	}
	for _, part := range parts {
		if part == "" {
			return orchestrator.ReviewerSlot{}, fmt.Errorf("--post-reviewer must use provider:model[:effort]")
		}
	}
	provider := parts[0]
	switch provider {
	case "claude", "codex", "gemini":
	default:
		return orchestrator.ReviewerSlot{}, fmt.Errorf("--post-reviewer provider must be claude, codex, or gemini")
	}
	mode := "fast"
	if len(parts) == 3 {
		parsed, err := parsePostReviewEffort(parts[2])
		if err != nil {
			return orchestrator.ReviewerSlot{}, err
		}
		mode = parsed
	}
	return orchestrator.ReviewerSlot{
		ID:            "cerberus-dedup#1",
		Provider:      provider,
		Model:         parts[1],
		Mode:          mode,
		Strategy:      "independent-verifier",
		InstanceIndex: 1,
	}, nil
}

func parsePostReviewEffort(value string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "low", "fast":
		return "fast", nil
	case "medium", "smart":
		return "smart", nil
	case "high", "max":
		return "max", nil
	default:
		return "", fmt.Errorf("--post-reviewer effort must be low, medium, high, fast, smart, or max")
	}
}

type resolvedReviewerConfig struct {
	reviewers []orchestrator.ReviewerSlot
	rosterID  string
	defaults  orchestrator.RosterDefaults
}

func resolveReviewers(opts spawnCodeReviewOptions) (resolvedReviewerConfig, error) {
	if opts.agents != "" {
		reviewers, rosterID, err := reviewersFromAgents(opts.agents)
		if err != nil {
			return resolvedReviewerConfig{}, err
		}
		if err := enforceDebateMinimumForReviewers(reviewers, opts.debate); err != nil {
			return resolvedReviewerConfig{}, err
		}
		return resolvedReviewerConfig{reviewers: reviewers, rosterID: rosterID}, err
	}

	file, err := roster.LoadRosters("")
	if err != nil {
		return resolvedReviewerConfig{}, err
	}
	slots, err := roster.ResolveWithOptions(file, roster.ResolveOptions{
		RosterName:   opts.roster,
		CLIReviewers: opts.reviewers,
		ReplaceSlot:  opts.replaceSlot,
		Debate:       opts.debate,
	})
	if err != nil {
		return resolvedReviewerConfig{}, err
	}
	rosterID := opts.roster
	if rosterID == "" {
		rosterID = "default"
	}
	return resolvedReviewerConfig{
		reviewers: reviewersFromRosterSlots(slots),
		rosterID:  rosterID,
		defaults:  defaultsFromRosterFile(file),
	}, nil
}

func enforceDebateMinimumForReviewers(reviewers []orchestrator.ReviewerSlot, debate bool) error {
	slots := make([]roster.RosterSlot, len(reviewers))
	for i, reviewer := range reviewers {
		slots[i] = roster.RosterSlot{
			Provider:      reviewer.Provider,
			Model:         reviewer.Model,
			Strategy:      reviewer.Strategy,
			PersonaPath:   reviewer.PersonaPath,
			Mode:          reviewer.Mode,
			InstanceID:    reviewer.ID,
			InstanceIndex: reviewer.InstanceIndex,
		}
	}
	return roster.EnforceDebateMinimum(slots, debate)
}

func reviewersFromRosterSlots(slots []roster.RosterSlot) []orchestrator.ReviewerSlot {
	reviewers := make([]orchestrator.ReviewerSlot, len(slots))
	for i, slot := range slots {
		reviewers[i] = orchestrator.ReviewerSlot{
			ID:            slot.InstanceID,
			Provider:      slot.Provider,
			Model:         slot.Model,
			Strategy:      slot.Strategy,
			PersonaPath:   slot.PersonaPath,
			Mode:          slot.Mode,
			InstanceIndex: slot.InstanceIndex,
		}
	}
	return reviewers
}

func defaultsFromRosterFile(file *roster.RostersFile) orchestrator.RosterDefaults {
	if file == nil {
		return orchestrator.RosterDefaults{}
	}
	defaults := orchestrator.RosterDefaults{Mode: file.Defaults.Mode}
	if file.Defaults.MaxRounds != nil {
		defaults.MaxRounds = *file.Defaults.MaxRounds
	}
	return defaults
}

func reviewersFromAgents(agents string) ([]orchestrator.ReviewerSlot, string, error) {
	parts := strings.Split(agents, ",")
	counts := make(map[string]int)
	reviewers := make([]orchestrator.ReviewerSlot, 0, len(parts))
	for _, part := range parts {
		provider := strings.TrimSpace(part)
		if provider == "" {
			return nil, "", fmt.Errorf("--agents contains an empty provider")
		}
		switch provider {
		case "claude", "codex", "gemini":
		default:
			return nil, "", fmt.Errorf("--agents contains unsupported provider %q", provider)
		}
		counts[provider]++
		model, _ := config.DefaultModelForProvider(provider)
		reviewers = append(reviewers, orchestrator.ReviewerSlot{
			ID:            fmt.Sprintf("%s#%d", provider, counts[provider]),
			Provider:      provider,
			Model:         model,
			InstanceIndex: counts[provider],
		})
	}
	if len(reviewers) == 0 {
		return nil, "", fmt.Errorf("--agents must name at least one provider")
	}
	return reviewers, "agents", nil
}

func buildCodeReviewPrompt(opts spawnCodeReviewOptions) ([]byte, error) {
	return buildReviewPrompt(opts)
}

func buildReviewPrompt(opts spawnCodeReviewOptions) ([]byte, error) {
	return prepareReviewPrompt(&opts)
}

func prepareReviewPrompt(opts *spawnCodeReviewOptions) ([]byte, error) {
	switch opts.artifactType {
	case "", "code":
		return buildCodeReviewPromptBody(*opts)
	case "plan", "spec", "epic-verify":
		content, focus, err := artifactReviewContent(*opts)
		if err != nil {
			return nil, err
		}
		opts.artifactContent = content
		opts.focus = focus
		return artifactReviewPrompt(*opts), nil
	case "ask":
		content, context, err := askReviewContent(*opts)
		if err != nil {
			return nil, err
		}
		opts.artifactContent = content
		opts.contextContent = context
		return nil, nil
	default:
		return nil, fmt.Errorf("unsupported artifact type %q", opts.artifactType)
	}
}

func buildCodeReviewPromptBody(opts spawnCodeReviewOptions) ([]byte, error) {
	var buf bytes.Buffer
	fmt.Fprintln(&buf, "# Code review")
	context, err := savedAuthorContext()
	if err != nil {
		return nil, err
	}
	if context != "" {
		fmt.Fprintf(&buf, "\nAuthor context:\n%s\n", context)
	}
	if opts.focus != "" {
		fmt.Fprintf(&buf, "\nFocus: %s\n", opts.focus)
	}
	if len(opts.excludes) > 0 {
		fmt.Fprintf(&buf, "\nExcluded pathspecs: %s\n", strings.Join(opts.excludes, ", "))
	}
	diff, err := codeReviewDiff(opts)
	if err != nil {
		return nil, err
	}
	if diff == "" {
		diff = "(no diff output)"
	}
	fmt.Fprintf(&buf, "\n```diff\n%s\n```\n", diff)
	return buf.Bytes(), nil
}

func artifactReviewContent(opts spawnCodeReviewOptions) (string, string, error) {
	if len(opts.positionals) == 0 {
		return "", "", fmt.Errorf("%s review requires input", opts.artifactType)
	}
	input := opts.positionals[0]
	if data, err := os.ReadFile(input); err == nil {
		return string(data), strings.Join(opts.positionals[1:], " "), nil
	} else if opts.artifactType != "epic-verify" {
		return "", "", fmt.Errorf("read %s review file %s: %w", opts.artifactType, input, err)
	}
	return strings.Join(opts.positionals, " "), "", nil
}

func artifactReviewPrompt(opts spawnCodeReviewOptions) []byte {
	if opts.focus == "" {
		return nil
	}
	var buf bytes.Buffer
	fmt.Fprintf(&buf, "Focus: %s\n", opts.focus)
	return buf.Bytes()
}

func askReviewContent(opts spawnCodeReviewOptions) (string, string, error) {
	content := strings.TrimSpace(opts.focus)
	if opts.promptFile != "" {
		data, err := os.ReadFile(opts.promptFile)
		if err != nil {
			return "", "", fmt.Errorf("read ask prompt file %s: %w", opts.promptFile, err)
		}
		content = string(data)
	}
	if strings.TrimSpace(content) == "" {
		return "", "", fmt.Errorf("ask prompt is required")
	}
	context := ""
	if opts.contextFile != "" {
		data, err := os.ReadFile(opts.contextFile)
		if err != nil {
			return "", "", fmt.Errorf("read ask context file %s: %w", opts.contextFile, err)
		}
		context = string(data)
	}
	return content, context, nil
}

func savedAuthorContext() (string, error) {
	runRoot, ok, err := activeRunRoot()
	if err != nil || !ok {
		return "", err
	}
	data, err := os.ReadFile(filepath.Join(runRoot, "author-context.json"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", err
	}
	var context struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(data, &context); err != nil {
		return "", fmt.Errorf("parse author context: %w", err)
	}
	return context.Text, nil
}

func codeReviewDiff(opts spawnCodeReviewOptions) (string, error) {
	return runGit(codeReviewGitArgs(opts))
}

func codeReviewGitArgs(opts spawnCodeReviewOptions) []string {
	args := []string{"diff", "--no-ext-diff"}
	if opts.uncommitted || (opts.base == "" && len(opts.commits) == 0) {
		args = append(args, "HEAD")
	} else if opts.base != "" {
		args = append(args, opts.base+"...HEAD")
	} else if len(opts.commits) > 0 {
		showArgs := append([]string{"show", "--format=fuller", "--stat", "--patch", "--no-ext-diff"}, opts.commits...)
		return appendExcludes(showArgs, opts.excludes)
	}
	return appendExcludes(args, opts.excludes)
}

func appendExcludes(args []string, excludes []string) []string {
	if len(excludes) == 0 {
		return args
	}
	args = append(args, "--", ".")
	for _, exclude := range excludes {
		args = append(args, excludePathspec(exclude))
	}
	return args
}

func excludePathspec(exclude string) string {
	if strings.HasPrefix(exclude, ":!") || strings.HasPrefix(exclude, ":^") || hasExcludeMagic(exclude) {
		return exclude
	}
	return ":(exclude)" + exclude
}

func hasExcludeMagic(pathspec string) bool {
	if !strings.HasPrefix(pathspec, ":(") {
		return false
	}
	end := strings.IndexByte(pathspec, ')')
	if end < 0 {
		return false
	}
	for _, magic := range strings.Split(pathspec[2:end], ",") {
		if magic == "exclude" {
			return true
		}
	}
	return false
}

func runGit(args []string) (string, error) {
	cmd := exec.Command("git", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s: %w\n%s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return string(output), nil
}

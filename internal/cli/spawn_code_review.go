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

	"github.com/charlieyou/cerberus/internal/aggregate"
	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/roster"
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
	opts, err := parseSpawnCodeReviewFlags(args, stderr)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	if opts.debate {
		fmt.Fprintln(stderr, "debate not yet implemented in Epic B; see Epic C")
		return 2
	}

	resolved, err := resolveReviewers(opts)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	prompt, err := buildCodeReviewPrompt(opts)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}

	params := orchestrator.Params{
		Prompt:         prompt,
		Reviewers:      resolved.reviewers,
		RosterDefaults: resolved.defaults,
		Mode:           opts.mode,
		MaxRounds:      opts.maxRounds,
		Consensus:      aggregate.Mode(opts.consensus),
		RosterID:       resolved.rosterID,
	}
	if err := orchestrator.RunSinglePass(context.Background(), config.Resolve(), params, nil); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	fmt.Fprintln(stdout, "review resolved")
	return 0
}

type spawnCodeReviewOptions struct {
	mode         string
	modeSet      bool
	maxRounds    int
	maxRoundsSet bool
	consensus    string
	agents       string
	roster       string
	reviewers    []string
	replaceSlot  string
	excludes     []string
	uncommitted  bool
	base         string
	commits      []string
	debate       bool
	focus        string
}

func parseSpawnCodeReviewFlags(args []string, stderr io.Writer) (spawnCodeReviewOptions, error) {
	var opts spawnCodeReviewOptions
	var reviewers repeatString
	var excludes repeatString
	var commits repeatString

	fs := flag.NewFlagSet("spawn-code-review", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&opts.mode, "mode", "smart", "review mode")
	fs.IntVar(&opts.maxRounds, "max-rounds", 1, "maximum review rounds")
	fs.StringVar(&opts.consensus, "consensus", "majority", "consensus mode")
	fs.StringVar(&opts.agents, "agents", "", "legacy comma-separated reviewer providers")
	fs.StringVar(&opts.roster, "roster", "", "roster name")
	fs.Var(&reviewers, "reviewer", "reviewer provider:model[:strategy]")
	fs.StringVar(&opts.replaceSlot, "replace-slot", "", "slot id to replace")
	fs.Var(&excludes, "exclude", "pathspec to exclude")
	fs.BoolVar(&opts.uncommitted, "uncommitted", false, "review uncommitted changes")
	fs.StringVar(&opts.base, "base", "", "base ref")
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
		opts.maxRounds = 0
	}
	if len(opts.commits) > 0 {
		opts.commits = append(opts.commits, fs.Args()...)
	} else {
		opts.focus = strings.Join(fs.Args(), " ")
	}
	if err := validateSpawnCodeReviewOptions(opts); err != nil {
		return opts, err
	}
	return opts, nil
}

func validateSpawnCodeReviewOptions(opts spawnCodeReviewOptions) error {
	if opts.mode != "" {
		switch opts.mode {
		case "fast", "smart", "max":
		default:
			return fmt.Errorf("--mode must be fast, smart, or max")
		}
	}
	if opts.maxRounds != 0 && opts.maxRounds <= 0 {
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
	if opts.uncommitted && (opts.base != "" || len(opts.commits) > 0) {
		return fmt.Errorf("--uncommitted is mutually exclusive with --base and --commit")
	}
	if opts.base != "" && len(opts.commits) > 0 {
		return fmt.Errorf("--base is mutually exclusive with --commit")
	}
	return nil
}

type resolvedReviewerConfig struct {
	reviewers []orchestrator.ReviewerSlot
	rosterID  string
	defaults  orchestrator.RosterDefaults
}

func resolveReviewers(opts spawnCodeReviewOptions) (resolvedReviewerConfig, error) {
	if opts.agents != "" {
		reviewers, rosterID, err := reviewersFromAgents(opts.agents)
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
		reviewers = append(reviewers, orchestrator.ReviewerSlot{
			ID:       fmt.Sprintf("%s#%d", provider, counts[provider]),
			Provider: provider,
			Model:    provider,
		})
	}
	if len(reviewers) == 0 {
		return nil, "", fmt.Errorf("--agents must name at least one provider")
	}
	return reviewers, "agents", nil
}

func buildCodeReviewPrompt(opts spawnCodeReviewOptions) ([]byte, error) {
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
		args = append(args, ":(exclude)"+exclude)
	}
	return args
}

func runGit(args []string) (string, error) {
	cmd := exec.Command("git", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s: %w\n%s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return string(output), nil
}

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/hook"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/state"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

func TestSpawnCodeReviewAgentsConsensusHappyPath(t *testing.T) {
	setSpawnTestEnv(t)
	startRuntimeInlineForTest(t, nil)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--consensus", "majority", "--agents", "claude,codex,gemini"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	gate := waitForSpawnGateStatus(t, state.StatusResolved)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	if gate.RosterID != "agents" {
		t.Fatalf("gate roster_id = %q, want agents", gate.RosterID)
	}
	assertRecordedModel(t, "claude", "claude-opus-4-7")
	assertRecordedModel(t, "codex", "gpt-5.5")
	assertRecordedModel(t, "gemini", "gemini-3.1-pro")
}

func TestSpawnCodeReviewBuiltInDefaultUsesConcreteModels(t *testing.T) {
	setSpawnTestEnv(t)
	startRuntimeInlineForTest(t, nil)
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--consensus", "majority"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	gate := waitForSpawnGateStatus(t, state.StatusResolved)
	if gate.RosterID != "default" {
		t.Fatalf("gate roster_id = %q, want default", gate.RosterID)
	}
	assertRecordedModel(t, "claude", "claude-opus-4-7")
	assertRecordedModel(t, "codex", "gpt-5.5")
	assertRecordedModel(t, "gemini", "gemini-3.1-pro")
}

func TestSurvivingSpawnAliasesDispatchReviewGate(t *testing.T) {
	cases := []struct {
		name       string
		subcommand string
		args       []string
		wantPrompt []string
	}{
		{
			name:       "plan file",
			subcommand: "spawn-plan-review",
			args:       []string{"--agents", "codex", writeSpawnFixture(t, "plan.md", "PLAN BODY")},
			wantPrompt: []string{"Implementation Plan Review Guidelines", "<plan>\nPLAN BODY\n</plan>"},
		},
		{
			name:       "plan file with focus",
			subcommand: "spawn-plan-review",
			args:       []string{"--agents", "codex", writeSpawnFixture(t, "focused-plan.md", "PLAN BODY"), "focus", "on", "error", "handling"},
			wantPrompt: []string{"Implementation Plan Review Guidelines", "<plan>\nPLAN BODY\n</plan>", "Focus: focus on error handling"},
		},
		{
			name:       "spec file",
			subcommand: "spawn-spec-review",
			args:       []string{"--agents", "codex", writeSpawnFixture(t, "spec.md", "SPEC BODY")},
			wantPrompt: []string{"Feature Specification Review Guidelines", "<spec>\nSPEC BODY\n</spec>"},
		},
		{
			name:       "ask inline",
			subcommand: "spawn-ask",
			args:       []string{"--agents", "codex", "codex smoke question"},
			wantPrompt: []string{"Ask Panel Guidelines", "<ask_prompt>\ncodex smoke question\n</ask_prompt>"},
		},
		{
			name:       "ask prompt and context files",
			subcommand: "spawn-ask",
			args: []string{
				"--agents", "codex",
				"--prompt-file", writeSpawnFixture(t, "question.md", "FILE QUESTION"),
				"--context-file", writeSpawnFixture(t, "context.md", "FILE CONTEXT"),
			},
			wantPrompt: []string{"<ask_prompt>\nFILE QUESTION\n</ask_prompt>", "<context>\nFILE CONTEXT\n</context>"},
		},
		{
			name:       "epic file",
			subcommand: "spawn-epic-verify",
			args:       []string{"--agents", "codex", writeSpawnFixture(t, "epic.md", "EPIC BODY")},
			wantPrompt: []string{"Epic Verification Guidelines", "<epic_context>\nEPIC BODY\n</epic_context>"},
		},
		{
			name:       "epic raw criteria",
			subcommand: "spawn-epic-verify",
			args:       []string{"--agents", "codex", "- Users can login"},
			wantPrompt: []string{"<epic_context>\n- Users can login\n</epic_context>"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			setSpawnTestEnv(t)
			startRuntimeInlineForTest(t, nil)
			var stdout, stderr bytes.Buffer
			args := append([]string{tc.subcommand}, tc.args...)

			code := run(args, &stdout, &stderr)

			if code != 0 {
				t.Fatalf("%s exit code = %d, want 0; stderr: %s", tc.subcommand, code, stderr.String())
			}
			if !strings.Contains(stdout.String(), "review spawned") {
				t.Fatalf("%s stdout = %q, want review spawned", tc.subcommand, stdout.String())
			}
			if gate := waitForSpawnGateStatus(t, state.StatusResolved); gate.Status != state.StatusResolved {
				t.Fatalf("%s gate status = %q, want resolved", tc.subcommand, gate.Status)
			}
			prompt := readSpawnReviewerPrompt(t, "codex#1")
			for _, want := range tc.wantPrompt {
				if !strings.Contains(prompt, want) {
					t.Fatalf("%s reviewer prompt missing %q:\n%s", tc.subcommand, want, prompt)
				}
			}
		})
	}
}

func TestSpawnCodeReviewRejectsAgentsWithRoster(t *testing.T) {
	setSpawnTestEnv(t)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--agents", "claude,codex,gemini", "--roster", "default"}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("spawn-code-review exit code = 0, want non-zero")
	}
	if !strings.Contains(stderr.String(), "--agents is mutually exclusive with --roster and --reviewer") {
		t.Fatalf("stderr = %q, want --agents mutex error", stderr.String())
	}
	events := readSpawnEventLog(t)
	event := findSpawnEvent(t, events, telemetry.EventPreflightFailed)
	if got, want := event["stage"], "flags"; got != want {
		t.Fatalf("preflight failed stage = %v, want %q", got, want)
	}
}

func TestSpawnCodeReviewDebateRejectsOneReviewerYAMLRoster(t *testing.T) {
	setSpawnTestEnv(t)
	setRosterTestCWD(t)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--debate"}, &stdout, &stderr)

	if code != ExitCodePreflight {
		t.Fatalf("spawn-code-review --debate exit code = %d, want %d", code, ExitCodePreflight)
	}
	if !strings.Contains(stderr.String(), "--debate requires at least 2 reviewers in the resolved roster (got 1)") {
		t.Fatalf("stderr = %q, want debate reviewer-count error", stderr.String())
	}
	if _, err := os.Stat(spawnGatePath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("gate-state stat error = %v, want not exist", err)
	}
	events := readSpawnEventLog(t)
	event := findSpawnEvent(t, events, telemetry.EventPreflightFailed)
	if got, want := event["reason"], "debate_min_reviewers"; got != want {
		t.Fatalf("preflight failed reason = %v, want %q", got, want)
	}
}

func TestSpawnCodeReviewDebateRejectsDegradedDefaultToOneReviewer(t *testing.T) {
	setSpawnTestEnv(t)
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())
	onlyCodexCLIOnPath(t)
	var stdout, stderr bytes.Buffer

	var code int
	osStderr := captureProcessStderr(t, func() {
		code = run([]string{"spawn-code-review", "--debate"}, &stdout, &stderr)
	})
	allStderr := stderr.String() + osStderr

	if code != ExitCodePreflight {
		t.Fatalf("spawn-code-review --debate exit code = %d, want %d", code, ExitCodePreflight)
	}
	for _, want := range []string{
		`warning: default panel CLI "claude" missing on PATH`,
		`warning: default panel CLI "gemini" missing on PATH`,
		"--debate requires at least 2 reviewers in the resolved roster (got 1)",
	} {
		if !strings.Contains(allStderr, want) {
			t.Fatalf("stderr = %q, want %q", allStderr, want)
		}
	}
	if _, err := os.Stat(spawnGatePath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("gate-state stat error = %v, want not exist", err)
	}
}

func TestSpawnCodeReviewDebateTwoReviewersDefaultMaxRounds(t *testing.T) {
	setSpawnTestEnv(t)
	startDebateRuntimeCaptureForTest(t)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--agents", "codex,claude", "--debate"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review --debate exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	gate := readSpawnGate(t)
	if !gate.Debate {
		t.Fatal("gate debate = false, want true")
	}
	if gate.MaxRounds != 3 {
		t.Fatalf("gate max_rounds = %d, want 3", gate.MaxRounds)
	}
	if gate.Status != state.StatusPending {
		t.Fatalf("gate status = %q, want pending before detached runtime completes", gate.Status)
	}
}

func TestSpawnCodeReviewDebateMaxRoundsOverride(t *testing.T) {
	setSpawnTestEnv(t)
	startDebateRuntimeCaptureForTest(t)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--agents", "codex,claude", "--debate", "--max-rounds", "5"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review --debate exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	gate := readSpawnGate(t)
	if !gate.Debate {
		t.Fatal("gate debate = false, want true")
	}
	if gate.MaxRounds != 5 {
		t.Fatalf("gate max_rounds = %d, want 5", gate.MaxRounds)
	}
}

func TestSpawnCodeReviewDebateUsesRosterDefaultsWhenFlagsOmitted(t *testing.T) {
	setSpawnTestEnv(t)
	started := startDebateRuntimeCaptureForTest(t)
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".cerberus"), 0o755); err != nil {
		t.Fatalf("MkdirAll(.cerberus) error = %v", err)
	}
	rosters := []byte(`version: 1
defaults:
  mode: max
  max_rounds: 5
rosters:
  default:
    reviewers:
      - provider: codex
        model: gpt
      - provider: claude
        model: opus
`)
	if err := os.WriteFile(filepath.Join(dir, ".cerberus", "rosters.yaml"), rosters, 0o644); err != nil {
		t.Fatalf("WriteFile(rosters.yaml) error = %v", err)
	}
	oldwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd() error = %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("Chdir(%s) error = %v", dir, err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(oldwd); err != nil {
			t.Fatalf("restore cwd %s: %v", oldwd, err)
		}
	})
	initEmptyGitRepo(t, dir)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--debate"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review --debate exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if (*started).Params.Mode != "max" {
		t.Fatalf("started debate mode = %q, want max", (*started).Params.Mode)
	}
	if (*started).Params.MaxRounds != 5 {
		t.Fatalf("started debate max_rounds = %d, want 5", (*started).Params.MaxRounds)
	}
}

func TestSpawnCodeReviewDebateRuntimeLaunchFailureResolvesPendingGate(t *testing.T) {
	setSpawnTestEnv(t)
	old := startDebateRuntime
	startDebateRuntime = func(started *orchestrator.StartedRun) error {
		return errors.New("debate launch failed")
	}
	t.Cleanup(func() {
		startDebateRuntime = old
	})
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--agents", "codex,claude", "--debate"}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("spawn-code-review exit code = 0, want non-zero")
	}
	gate := readSpawnGate(t)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictRequiresDecision {
		t.Fatalf("gate verdict = %v, want requires_decision", gate.Verdict)
	}
	if !strings.Contains(gate.ResolutionReason, "debate launch failed") {
		t.Fatalf("resolution reason = %q, want launch failure", gate.ResolutionReason)
	}
}

func TestSpawnCodeReviewRecordsResolvePreflightFailure(t *testing.T) {
	setSpawnTestEnv(t)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--agents", "unknown"}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("spawn-code-review exit code = 0, want non-zero")
	}
	events := readSpawnEventLog(t)
	event := findSpawnEvent(t, events, telemetry.EventPreflightFailed)
	if got, want := event["stage"], "roster"; got != want {
		t.Fatalf("preflight failed stage = %v, want %q", got, want)
	}
	if !strings.Contains(event["error"].(string), `unsupported provider "unknown"`) {
		t.Fatalf("preflight failed error = %v, want unsupported provider", event["error"])
	}
}

func TestSpawnCodeReviewCreatesPendingGateObservedByHookPoll(t *testing.T) {
	setSpawnTestEnv(t)
	releaseRuntime := make(chan struct{})
	startRuntimeInlineForTest(t, func() {
		<-releaseRuntime
	})
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--agents", "claude,codex,gemini"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	gate := readSpawnGate(t)
	if gate.Status != state.StatusPending {
		t.Fatalf("gate status after spawn = %q, want pending", gate.Status)
	}
	done := make(chan error, 1)
	go func() {
		done <- hook.PollGateState(spawnGatePath(), 10*time.Millisecond, time.Second)
	}()
	select {
	case err := <-done:
		t.Fatalf("hook poll returned while gate pending: %v", err)
	case <-time.After(50 * time.Millisecond):
	}

	close(releaseRuntime)
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("hook poll error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("hook poll did not return after gate resolved")
	}
	gate = readSpawnGate(t)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status after runtime = %q, want resolved", gate.Status)
	}
}

func TestSpawnCodeReviewRuntimeLaunchFailureResolvesPendingGate(t *testing.T) {
	setSpawnTestEnv(t)
	old := startReviewRuntime
	startReviewRuntime = func(started *orchestrator.StartedRun) error {
		return errors.New("runtime launch failed")
	}
	t.Cleanup(func() {
		startReviewRuntime = old
	})
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--agents", "codex"}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("spawn-code-review exit code = 0, want non-zero")
	}
	gate := readSpawnGate(t)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictRequiresDecision {
		t.Fatalf("gate verdict = %v, want requires_decision", gate.Verdict)
	}
	if !strings.Contains(gate.ResolutionReason, "runtime launch failed") {
		t.Fatalf("resolution reason = %q, want launch failure", gate.ResolutionReason)
	}
	if err := hook.PollGateState(spawnGatePath(), 10*time.Millisecond, time.Second); err != nil {
		t.Fatalf("PollGateState() error = %v", err)
	}
}

func TestSinglePassRuntimeFailureResolvesPendingGate(t *testing.T) {
	setSpawnTestEnv(t)
	t.Setenv("CERBERUS_MOCK_EXIT", "1")
	started, err := orchestrator.StartSinglePass(nil, orchestrator.Params{
		Prompt: []byte("review this"),
		Reviewers: []orchestrator.ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	})
	if err != nil {
		t.Fatalf("StartSinglePass() error = %v", err)
	}
	requestPath := filepath.Join(started.RunRoot, "single-pass-request.json")
	data, err := json.Marshal(started)
	if err != nil {
		t.Fatalf("Marshal(started) error = %v", err)
	}
	if err := os.WriteFile(requestPath, data, 0o644); err != nil {
		t.Fatalf("WriteFile(request) error = %v", err)
	}
	var stdout, stderr bytes.Buffer

	code := runSinglePassRuntime([]string{requestPath}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("runSinglePassRuntime exit code = 0, want non-zero")
	}
	gate := readSpawnGate(t)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictRequiresDecision {
		t.Fatalf("gate verdict = %v, want requires_decision", gate.Verdict)
	}
	if !strings.Contains(gate.ResolutionReason, "single-pass runtime failed") {
		t.Fatalf("resolution reason = %q, want runtime failure", gate.ResolutionReason)
	}
	if err := hook.PollGateState(spawnGatePath(), 10*time.Millisecond, time.Second); err != nil {
		t.Fatalf("PollGateState() error = %v", err)
	}
}

func TestDebateRuntimeFailureResolvesPendingGate(t *testing.T) {
	setSpawnTestEnv(t)
	t.Setenv("CERBERUS_MOCK_EXIT", "1")
	started, err := (orchestrator.Orchestrator{}).StartDebate(orchestrator.Params{
		Prompt: []byte("review this"),
		Reviewers: []orchestrator.ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub", InstanceIndex: 1},
			{ID: "claude#1", Provider: "claude", Model: "stub", InstanceIndex: 1},
		},
	})
	if err != nil {
		t.Fatalf("StartDebate() error = %v", err)
	}
	requestPath := filepath.Join(started.RunRoot, "debate-request.json")
	data, err := json.Marshal(started)
	if err != nil {
		t.Fatalf("Marshal(started) error = %v", err)
	}
	if err := os.WriteFile(requestPath, data, 0o644); err != nil {
		t.Fatalf("WriteFile(request) error = %v", err)
	}
	var stdout, stderr bytes.Buffer

	code := runDebateRuntime([]string{requestPath}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("runDebateRuntime exit code = 0, want non-zero")
	}
	gate := readSpawnGate(t)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictRequiresDecision {
		t.Fatalf("gate verdict = %v, want requires_decision", gate.Verdict)
	}
	if !strings.Contains(gate.ResolutionReason, "debate runtime failed") {
		t.Fatalf("resolution reason = %q, want runtime failure", gate.ResolutionReason)
	}
	if err := hook.PollGateState(spawnGatePath(), 10*time.Millisecond, time.Second); err != nil {
		t.Fatalf("PollGateState() error = %v", err)
	}
}

func TestReviewersFromAgentsUsesProviderOccurrenceForInstanceIndex(t *testing.T) {
	reviewers, rosterID, err := reviewersFromAgents("codex,claude")
	if err != nil {
		t.Fatalf("reviewersFromAgents() error = %v", err)
	}
	if rosterID != "agents" {
		t.Fatalf("rosterID = %q, want agents", rosterID)
	}
	if got, want := len(reviewers), 2; got != want {
		t.Fatalf("len(reviewers) = %d, want %d", got, want)
	}
	if reviewers[1].ID != "claude#1" {
		t.Fatalf("second reviewer ID = %q, want claude#1", reviewers[1].ID)
	}
	if got, want := reviewers[1].InstanceIndex, 1; got != want {
		t.Fatalf("claude#1 instance index = %d, want %d", got, want)
	}
}

func TestParseSpawnCodeReviewReviewerGrammarAndReplace(t *testing.T) {
	var stderr bytes.Buffer

	opts, err := parseSpawnCodeReviewFlags([]string{
		"--roster", "default",
		"--reviewer", "claude:opus",
		"--reviewer", "codex:gpt-5.3-codex:falsification-first",
		"--replace-slot", "claude#1",
		"--consensus", "all",
	}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags() error = %v", err)
	}
	if opts.roster != "default" || opts.replaceSlot != "claude#1" || opts.consensus != "all" {
		t.Fatalf("parsed options = %#v, want roster/replace/consensus", opts)
	}
	if opts.mode != "" || opts.maxRounds != 3 {
		t.Fatalf("implicit mode/maxRounds = %q/%d, want empty/3", opts.mode, opts.maxRounds)
	}
	if got, want := strings.Join(opts.reviewers, ","), "claude:opus,codex:gpt-5.3-codex:falsification-first"; got != want {
		t.Fatalf("reviewers = %q, want %q", got, want)
	}

	_, err = parseSpawnCodeReviewFlags([]string{"--reviewer", "claude:model:strategy:extra"}, &stderr)
	if err == nil || !strings.Contains(err.Error(), "--reviewer must use provider:model[:strategy]") {
		t.Fatalf("long reviewer parse error = %v, want grammar error", err)
	}
}

func TestParseSpawnCodeReviewPreservesExplicitModeAndMaxRounds(t *testing.T) {
	var stderr bytes.Buffer

	opts, err := parseSpawnCodeReviewFlags([]string{"--mode", "smart", "--max-rounds", "5"}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags() error = %v", err)
	}
	if opts.mode != "smart" || opts.maxRounds != 5 {
		t.Fatalf("mode/maxRounds = %q/%d, want smart/5", opts.mode, opts.maxRounds)
	}
}

func TestParseSpawnCodeReviewRejectsExplicitInvalidRuntimeFlags(t *testing.T) {
	var stderr bytes.Buffer

	_, err := parseSpawnCodeReviewFlags([]string{"--max-rounds", "0"}, &stderr)
	if err == nil || !strings.Contains(err.Error(), "--max-rounds must be positive") {
		t.Fatalf("zero max-rounds error = %v, want positive error", err)
	}

	_, err = parseSpawnCodeReviewFlags([]string{"--mode", ""}, &stderr)
	if err == nil || !strings.Contains(err.Error(), "--mode must be fast, smart, or max") {
		t.Fatalf("empty mode error = %v, want mode enum error", err)
	}
}

func TestParseSpawnCodeReviewCommitConsumesAllTrailingRevisions(t *testing.T) {
	var stderr bytes.Buffer

	opts, err := parseSpawnCodeReviewFlags([]string{"--commit", "HEAD", "HEAD~0"}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags() error = %v", err)
	}
	if got, want := strings.Join(opts.commits, ","), "HEAD,HEAD~0"; got != want {
		t.Fatalf("commits = %q, want %q", got, want)
	}
	if opts.focus != "" {
		t.Fatalf("focus = %q, want empty for trailing --commit revisions", opts.focus)
	}
}

func TestParseSpawnCodeReviewCommitKeepsTrailingFocus(t *testing.T) {
	var stderr bytes.Buffer

	opts, err := parseSpawnCodeReviewFlags([]string{"--commit", "HEAD", "api:", "error", "handling"}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags() error = %v", err)
	}
	if got, want := strings.Join(opts.commits, ","), "HEAD"; got != want {
		t.Fatalf("commits = %q, want %q", got, want)
	}
	if got, want := opts.focus, "api: error handling"; got != want {
		t.Fatalf("focus = %q, want %q", got, want)
	}
}

func TestResolveReviewersAppendsCLIReviewer(t *testing.T) {
	setRosterTestCWD(t)

	resolved, err := resolveReviewers(spawnCodeReviewOptions{
		roster:    "default",
		reviewers: []string{"claude:opus"},
	})
	if err != nil {
		t.Fatalf("resolveReviewers() error = %v", err)
	}
	if resolved.rosterID != "default" {
		t.Fatalf("rosterID = %q, want default", resolved.rosterID)
	}
	if got, want := len(resolved.reviewers), 2; got != want {
		t.Fatalf("len(reviewers) = %d, want %d", got, want)
	}
	if resolved.reviewers[0].ID != "codex#1" || resolved.reviewers[1].ID != "claude#1" {
		t.Fatalf("reviewer IDs = %#v, want codex#1 then claude#1", resolved.reviewers)
	}
}

func TestResolveReviewersReplacesSlot(t *testing.T) {
	setRosterTestCWD(t)

	resolved, err := resolveReviewers(spawnCodeReviewOptions{
		roster:      "default",
		reviewers:   []string{"claude:opus"},
		replaceSlot: "codex#1",
	})
	if err != nil {
		t.Fatalf("resolveReviewers() error = %v", err)
	}
	if got, want := len(resolved.reviewers), 1; got != want {
		t.Fatalf("len(reviewers) = %d, want %d", got, want)
	}
	if resolved.reviewers[0].ID != "claude#1" || resolved.reviewers[0].Provider != "claude" || resolved.reviewers[0].Model != "opus" {
		t.Fatalf("reviewer = %#v, want claude#1 opus", resolved.reviewers[0])
	}
}

func TestResolveReviewersPreservesStrategy(t *testing.T) {
	setRosterTestCWD(t)
	writeStrategy(t, "falsification-first")

	resolved, err := resolveReviewers(spawnCodeReviewOptions{
		roster:    "default",
		reviewers: []string{"claude:opus:falsification-first"},
	})
	if err != nil {
		t.Fatalf("resolveReviewers() error = %v", err)
	}
	if got, want := resolved.reviewers[1].Strategy, "falsification-first"; got != want {
		t.Fatalf("reviewer strategy = %q, want %q", got, want)
	}
}

func TestResolveReviewersCarriesRosterDefaultsAndSlotMode(t *testing.T) {
	setSpawnTestEnv(t)
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".cerberus"), 0o755); err != nil {
		t.Fatalf("MkdirAll(.cerberus) error = %v", err)
	}
	rosters := []byte(`version: 1
defaults:
  mode: max
  max_rounds: 3
rosters:
  default:
    reviewers:
      - provider: codex
        model: gpt
        mode: fast
`)
	if err := os.WriteFile(filepath.Join(dir, ".cerberus", "rosters.yaml"), rosters, 0o644); err != nil {
		t.Fatalf("WriteFile(rosters.yaml) error = %v", err)
	}
	oldwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd() error = %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("Chdir(%s) error = %v", dir, err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(oldwd); err != nil {
			t.Fatalf("restore cwd %s: %v", oldwd, err)
		}
	})

	resolved, err := resolveReviewers(spawnCodeReviewOptions{})
	if err != nil {
		t.Fatalf("resolveReviewers() error = %v", err)
	}
	if resolved.defaults.Mode != "max" || resolved.defaults.MaxRounds != 3 {
		t.Fatalf("defaults = %#v, want mode max max_rounds 3", resolved.defaults)
	}
	if got, want := resolved.reviewers[0].Mode, "fast"; got != want {
		t.Fatalf("reviewer mode = %q, want %q", got, want)
	}
	if got, want := resolved.reviewers[0].InstanceIndex, 1; got != want {
		t.Fatalf("reviewer instance index = %d, want %d", got, want)
	}
}

func TestCodeReviewGitArgsAppliesExcludeToCommitReview(t *testing.T) {
	args := codeReviewGitArgs(spawnCodeReviewOptions{
		commits:  []string{"abc123"},
		excludes: []string{"vendor/**"},
	})

	got := strings.Join(args, " ")
	if !strings.Contains(got, "show --format=fuller --stat --patch --no-ext-diff abc123 -- . :(exclude)vendor/**") {
		t.Fatalf("git args = %q, want commit review with exclude pathspec", got)
	}
}

func TestCodeReviewGitArgsPreservesExcludePathspecMagic(t *testing.T) {
	args := codeReviewGitArgs(spawnCodeReviewOptions{
		commits:  []string{"abc123"},
		excludes: []string{":(exclude,glob)dist/**", ":(glob,exclude)internal/**", ":!vendor/**"},
	})

	got := strings.Join(args, " ")
	if !strings.Contains(got, " -- . :(exclude,glob)dist/** :(glob,exclude)internal/** :!vendor/**") {
		t.Fatalf("git args = %q, want existing exclude pathspec magic preserved", got)
	}
	if strings.Contains(got, ":(exclude):(") || strings.Contains(got, ":(exclude):!") {
		t.Fatalf("git args = %q, want no double exclude prefix", got)
	}
}

func TestCodeReviewGitArgsDefaultIncludesStagedChanges(t *testing.T) {
	args := codeReviewGitArgs(spawnCodeReviewOptions{})

	if got, want := strings.Join(args, " "), "diff --no-ext-diff HEAD"; got != want {
		t.Fatalf("git args = %q, want %q", got, want)
	}
}

func TestBuildCodeReviewPromptIncludesSavedAuthorContext(t *testing.T) {
	setSpawnTestEnv(t)
	runRoot := state.RunDir(os.Getenv("CERBERUS_STATE_ROOT"), "project", "run")
	if err := state.EnsureRunDir(runRoot); err != nil {
		t.Fatalf("EnsureRunDir() error = %v", err)
	}
	context := []byte("{\"text\":\"Resolved flaky test concern.\",\"updated_at\":\"2026-05-09T00:00:00Z\"}\n")
	if err := os.WriteFile(filepath.Join(runRoot, "author-context.json"), context, 0o644); err != nil {
		t.Fatalf("WriteFile(author-context.json) error = %v", err)
	}

	prompt, err := buildCodeReviewPrompt(spawnCodeReviewOptions{})
	if err != nil {
		t.Fatalf("buildCodeReviewPrompt() error = %v", err)
	}
	if !strings.Contains(string(prompt), "Author context:\nResolved flaky test concern.") {
		t.Fatalf("prompt = %q, want saved author context", prompt)
	}
}

func TestAuthorContextAbsentPrintsEmptyOutput(t *testing.T) {
	setSpawnTestEnv(t)
	var stdout, stderr bytes.Buffer

	code := run([]string{"author-context"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("author-context exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("author-context stdout = %q, want empty", stdout.String())
	}
}

func TestResolvePersistsReason(t *testing.T) {
	setSpawnTestEnv(t)
	runRoot := state.RunDir(os.Getenv("CERBERUS_STATE_ROOT"), "project", "run")
	path := state.GateStatePath(runRoot)
	if err := state.WriteGateState(path, &state.GateState{
		RunKey:           "run",
		Host:             "generic",
		ProjectKey:       "project",
		Status:           state.StatusPending,
		CurrentIteration: 1,
		MaxRounds:        1,
		RosterID:         "default",
	}); err != nil {
		t.Fatalf("WriteGateState() error = %v", err)
	}
	var stdout, stderr bytes.Buffer

	code := run([]string{"resolve", "--reason", "flaky test"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("resolve exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	gate, err := state.ReadGateState(path)
	if err != nil {
		t.Fatalf("ReadGateState() error = %v", err)
	}
	if gate.ResolutionReason != "flaky test" {
		t.Fatalf("resolution_reason = %q, want flaky test", gate.ResolutionReason)
	}
}

func setSpawnTestEnv(t *testing.T) {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	t.Setenv("PATH", spawnTestMockPath(t, repoRoot)+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CERBERUS_ROOT", repoRoot)
	t.Setenv("CERBERUS_HOST", "generic")
	t.Setenv("CERBERUS_STATE_ROOT", t.TempDir())
	t.Setenv("CERBERUS_PROJECT_KEY", "project")
	t.Setenv("CERBERUS_RUN_KEY", "run")
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())
}

func spawnTestMockPath(t *testing.T, repoRoot string) string {
	t.Helper()
	binDir := t.TempDir()
	for _, provider := range []string{"claude", "codex", "gemini"} {
		binary := filepath.Join(binDir, provider)
		build := exec.Command("go", "build", "-o", binary, "./tests/mocks/"+provider)
		build.Dir = repoRoot
		if output, err := build.CombinedOutput(); err != nil {
			t.Fatalf("go build ./tests/mocks/%s failed: %v\n%s", provider, err, output)
		}
	}
	return binDir
}

func onlyCodexCLIOnPath(t *testing.T) {
	t.Helper()
	bin := t.TempDir()
	path := filepath.Join(bin, "codex")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("WriteFile(codex) error = %v", err)
	}
	t.Setenv("PATH", bin)
}

func initEmptyGitRepo(t *testing.T, dir string) {
	t.Helper()
	for _, args := range [][]string{
		{"init"},
		{"config", "user.email", "test@example.com"},
		{"config", "user.name", "Test User"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, output)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("test\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(README.md) error = %v", err)
	}
	for _, args := range [][]string{
		{"add", "README.md"},
		{"commit", "-m", "initial"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, output)
		}
	}
}

func captureProcessStderr(t *testing.T, fn func()) string {
	t.Helper()
	original := os.Stderr
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatalf("Pipe() error = %v", err)
	}
	os.Stderr = write
	defer func() {
		os.Stderr = original
	}()

	fn()
	if err := write.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	var buf bytes.Buffer
	if _, err := buf.ReadFrom(read); err != nil {
		t.Fatalf("ReadFrom() error = %v", err)
	}
	return buf.String()
}

func setRosterTestCWD(t *testing.T) {
	t.Helper()
	setSpawnTestEnv(t)
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".cerberus"), 0o755); err != nil {
		t.Fatalf("MkdirAll(.cerberus) error = %v", err)
	}
	rosters := []byte("version: 1\nrosters:\n  default:\n    reviewers:\n      - provider: codex\n        model: gpt\n")
	if err := os.WriteFile(filepath.Join(dir, ".cerberus", "rosters.yaml"), rosters, 0o644); err != nil {
		t.Fatalf("WriteFile(rosters.yaml) error = %v", err)
	}
	oldwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd() error = %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("Chdir(%s) error = %v", dir, err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(oldwd); err != nil {
			t.Fatalf("restore cwd %s: %v", oldwd, err)
		}
	})
}

func writeStrategy(t *testing.T, name string) {
	t.Helper()
	dir := filepath.Join("prompts", "strategies")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("MkdirAll(%s) error = %v", dir, err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".md"), []byte("Strategy: "+name+"."), 0o644); err != nil {
		t.Fatalf("WriteFile(strategy) error = %v", err)
	}
}

func readSpawnGate(t *testing.T) *state.GateState {
	t.Helper()
	gate, err := state.ReadGateState(spawnGatePath())
	if err != nil {
		t.Fatalf("ReadGateState() error = %v", err)
	}
	return gate
}

func spawnGatePath() string {
	return state.GateStatePath(state.RunDir(os.Getenv("CERBERUS_STATE_ROOT"), "project", "run"))
}

func readSpawnEventLog(t *testing.T) []map[string]any {
	t.Helper()
	path := filepath.Join(os.Getenv("CERBERUS_STATE_ROOT"), "project", "run", "event-log.jsonl")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	events := make([]map[string]any, 0, len(lines))
	for _, line := range lines {
		var event map[string]any
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("Unmarshal event %q error = %v", line, err)
		}
		events = append(events, event)
	}
	return events
}

func readSpawnReviewerPrompt(t *testing.T, reviewerID string) string {
	t.Helper()
	path := filepath.Join(os.Getenv("CERBERUS_STATE_ROOT"), "project", "run", "iterations", "1", "round-1", "reviewers", reviewerID, "prompt.md")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	return string(data)
}

func writeSpawnFixture(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
	return path
}

func findSpawnEvent(t *testing.T, events []map[string]any, eventName string) map[string]any {
	t.Helper()
	for _, event := range events {
		if event["event"] == eventName {
			return event
		}
	}
	t.Fatalf("missing event %s in %#v", eventName, events)
	return nil
}

func startRuntimeInlineForTest(t *testing.T, beforeComplete func()) {
	t.Helper()
	old := startReviewRuntime
	startReviewRuntime = func(started *orchestrator.StartedRun) error {
		go func() {
			if beforeComplete != nil {
				beforeComplete()
			}
			_ = orchestrator.CompleteSinglePass(context.Background(), started, nil)
		}()
		return nil
	}
	t.Cleanup(func() {
		startReviewRuntime = old
	})
}

func startDebateRuntimeCaptureForTest(t *testing.T) **orchestrator.StartedRun {
	t.Helper()
	old := startDebateRuntime
	var captured *orchestrator.StartedRun
	startDebateRuntime = func(started *orchestrator.StartedRun) error {
		captured = started
		return nil
	}
	t.Cleanup(func() {
		startDebateRuntime = old
	})
	return &captured
}

func waitForSpawnGateStatus(t *testing.T, want string) *state.GateState {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	var last *state.GateState
	for time.Now().Before(deadline) {
		gate, err := state.ReadGateState(spawnGatePath())
		if err == nil {
			last = gate
			if gate.Status == want {
				return gate
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	if last == nil {
		t.Fatalf("gate status never reached %q; gate was not readable", want)
	}
	t.Fatalf("gate status = %q, want %q", last.Status, want)
	return nil
}

func assertRecordedModel(t *testing.T, provider, want string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(os.Getenv("CERBERUS_MOCK_RECORD_DIR"), provider+".args"))
	if err != nil {
		t.Fatalf("ReadFile(%s.args) error = %v", provider, err)
	}
	if !strings.Contains(string(data), "--model\n"+want+"\n") {
		t.Fatalf("%s args = %q, want model %q", provider, string(data), want)
	}
	if strings.Contains(string(data), "--model\n"+provider+"\n") {
		t.Fatalf("%s args = %q, must not use provider name as model", provider, string(data))
	}
}

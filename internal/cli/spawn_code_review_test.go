package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/hook"
	"github.com/charlieyou/cerberus/internal/host"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/state"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

func TestSpawnCodeReviewModeConsensusHappyPath(t *testing.T) {
	setSpawnTestEnv(t)
	startRuntimeInlineForTest(t, nil)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--consensus", "majority"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "review spawned (run key: run)") {
		t.Fatalf("stdout = %q, want spawned message with run key", stdout.String())
	}
	gate := waitForSpawnGateStatus(t, state.StatusResolved)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	if gate.Mode != "smart" {
		t.Fatalf("gate mode = %q, want smart", gate.Mode)
	}
	assertRecordedModel(t, "claude", "opus[1m]")
	assertRecordedModel(t, "codex", "gpt-5.6-sol")
	assertRecordedModel(t, "gemini", "gemini-3.1-pro-preview")
}

func TestSpawnCodeReviewRejectsPendingGate(t *testing.T) {
	setSpawnTestEnv(t)
	runRoot := state.RunDir(os.Getenv("CERBERUS_STATE_ROOT"), os.Getenv("CERBERUS_PROJECT_KEY"), os.Getenv("CERBERUS_RUN_KEY"))
	if err := state.WriteGateState(state.GateStatePath(runRoot), &state.GateState{
		RunKey:           os.Getenv("CERBERUS_RUN_KEY"),
		Host:             os.Getenv("CERBERUS_HOST"),
		ProjectKey:       os.Getenv("CERBERUS_PROJECT_KEY"),
		Status:           state.StatusPending,
		CurrentIteration: 1,
		MaxRounds:        1,
		Mode:             "smart",
	}); err != nil {
		t.Fatalf("seed gate state: %v", err)
	}
	launched := false
	old := startReviewRuntime
	startReviewRuntime = func(started *orchestrator.StartedRun) error {
		launched = true
		return nil
	}
	t.Cleanup(func() { startReviewRuntime = old })
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review"}, &stdout, &stderr)

	if code != 6 {
		t.Fatalf("spawn-code-review exit code = %d, want 6; stderr: %s", code, stderr.String())
	}
	if launched {
		t.Fatal("runtime launcher was called for pending gate rejection")
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout = %q, want empty", stdout.String())
	}
	if got := stderr.String(); !strings.Contains(got, "review already pending") || !strings.Contains(got, "CERBERUS_RUN_KEY") {
		t.Fatalf("stderr = %q, want pending gate guidance", got)
	}
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
	if gate.Mode != "smart" {
		t.Fatalf("gate mode = %q, want smart", gate.Mode)
	}
	assertRecordedModel(t, "claude", "opus[1m]")
	assertRecordedModel(t, "codex", "gpt-5.6-sol")
	assertRecordedModel(t, "gemini", "gemini-3.1-pro-preview")
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
			args:       []string{writeSpawnFixture(t, "plan.md", "PLAN BODY")},
			wantPrompt: []string{"Implementation Plan Review Guidelines", "<plan>\nPLAN BODY\n</plan>"},
		},
		{
			name:       "plan file with focus",
			subcommand: "spawn-plan-review",
			args:       []string{writeSpawnFixture(t, "focused-plan.md", "PLAN BODY"), "focus", "on", "error", "handling"},
			wantPrompt: []string{"Implementation Plan Review Guidelines", "<plan>\nPLAN BODY\n</plan>", "Focus: focus on error handling"},
		},
		{
			name:       "spec file",
			subcommand: "spawn-spec-review",
			args:       []string{writeSpawnFixture(t, "spec.md", "SPEC BODY")},
			wantPrompt: []string{"Feature Specification Review Guidelines", "<spec>\nSPEC BODY\n</spec>"},
		},
		{
			name:       "ask inline",
			subcommand: "spawn-ask",
			args:       []string{"codex smoke question"},
			wantPrompt: []string{"Ask Panel Guidelines", "<ask_prompt>\ncodex smoke question\n</ask_prompt>"},
		},
		{
			name:       "ask prompt and context files",
			subcommand: "spawn-ask",
			args: []string{
				"--prompt-file", writeSpawnFixture(t, "question.md", "FILE QUESTION"),
				"--context-file", writeSpawnFixture(t, "context.md", "FILE CONTEXT"),
			},
			wantPrompt: []string{"<ask_prompt>\nFILE QUESTION\n</ask_prompt>", "<context>\nFILE CONTEXT\n</context>"},
		},
		{
			name:       "epic file",
			subcommand: "spawn-epic-verify",
			args:       []string{writeSpawnFixture(t, "epic.md", "EPIC BODY")},
			wantPrompt: []string{"Epic Verification Guidelines", "<epic_context>\nEPIC BODY\n</epic_context>"},
		},
		{
			name:       "epic raw criteria",
			subcommand: "spawn-epic-verify",
			args:       []string{"- Users can login"},
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

func TestSpawnCodeReviewRejectsRemovedRosterFlag(t *testing.T) {
	setSpawnTestEnv(t)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--roster", "default"}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("spawn-code-review exit code = 0, want non-zero")
	}
	if !strings.Contains(stderr.String(), "flag provided but not defined: -roster") {
		t.Fatalf("stderr = %q, want removed flag error", stderr.String())
	}
	events := readSpawnEventLog(t)
	event := findSpawnEvent(t, events, telemetry.EventPreflightFailed)
	if got, want := event["stage"], "flags"; got != want {
		t.Fatalf("preflight failed stage = %v, want %q", got, want)
	}
}

func TestSpawnEpicVerifyRejectsRemovedFlagsAfterArtifact(t *testing.T) {
	for _, flagName := range []string{"--agents", "--roster", "--reviewer", "--replace-slot"} {
		t.Run(flagName, func(t *testing.T) {
			setSpawnTestEnv(t)
			var stdout, stderr bytes.Buffer

			code := run([]string{"spawn-epic-verify", "epic.md", flagName, "removed-value"}, &stdout, &stderr)

			if code == 0 {
				t.Fatalf("spawn-epic-verify %s exit code = 0, want non-zero", flagName)
			}
			want := "flag provided but not defined: -" + strings.TrimLeft(flagName, "-")
			if !strings.Contains(stderr.String(), want) {
				t.Fatalf("stderr = %q, want %q", stderr.String(), want)
			}
		})
	}
}

func TestArtifactReviewsParseFlagsAfterArtifact(t *testing.T) {
	for _, artifactType := range []string{"plan", "spec", "epic-verify"} {
		t.Run(artifactType, func(t *testing.T) {
			normalized, err := normalizeReviewArgs([]string{"artifact.md", "focus on auth", "--mode", "deep-review", "--consensus=all"}, artifactType)
			if err != nil {
				t.Fatalf("normalizeReviewArgs() error = %v", err)
			}
			opts, err := parseSpawnCodeReviewFlags(normalized, &bytes.Buffer{})
			if err != nil {
				t.Fatalf("parseSpawnCodeReviewFlags() error = %v", err)
			}
			if opts.mode != "deep-review" {
				t.Fatalf("mode = %q, want deep-review", opts.mode)
			}
			if opts.consensus != "all" {
				t.Fatalf("consensus = %q, want all", opts.consensus)
			}
			if got, want := opts.positionals, []string{"artifact.md", "focus on auth"}; !reflect.DeepEqual(got, want) {
				t.Fatalf("positionals = %#v, want %#v", got, want)
			}
		})
	}
}

func TestReviewFlagsRejectFlagShapedValues(t *testing.T) {
	for _, artifactType := range []string{"code", "plan", "spec", "epic-verify"} {
		t.Run(artifactType, func(t *testing.T) {
			_, err := normalizeReviewArgs([]string{"--context-file", "--roster", "artifact.md"}, artifactType)
			if err == nil || !strings.Contains(err.Error(), "flag needs an argument: --context-file") {
				t.Fatalf("normalizeReviewArgs() error = %v, want missing context-file value", err)
			}
		})
	}
}

func TestReviewHelpFlagsReachFlagParser(t *testing.T) {
	for _, artifactType := range []string{"code", "epic-verify"} {
		normalized, err := normalizeReviewArgs([]string{"--help"}, artifactType)
		if err != nil {
			t.Fatalf("normalizeReviewArgs(%s) error = %v", artifactType, err)
		}
		_, err = parseSpawnCodeReviewFlags(normalized, &bytes.Buffer{})
		if !errors.Is(err, flag.ErrHelp) {
			t.Fatalf("parseSpawnCodeReviewFlags(%s) error = %v, want flag.ErrHelp", artifactType, err)
		}
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

	code := run([]string{"spawn-code-review", "--debate"}, &stdout, &stderr)

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

	code := run([]string{"spawn-code-review", "--debate", "--max-rounds", "5"}, &stdout, &stderr)

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

func TestSpawnCodeReviewZeroMaxRoundsRunsSingleIteration(t *testing.T) {
	setSpawnTestEnv(t)
	started := startDebateRuntimeCaptureForTest(t)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--debate", "--max-rounds", "0"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review --max-rounds 0 exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if (*started).Params.MaxRounds != 1 {
		t.Fatalf("started max_rounds = %d, want 1", (*started).Params.MaxRounds)
	}
	if gate := readSpawnGate(t); gate.MaxRounds != 1 {
		t.Fatalf("gate max_rounds = %d, want 1", gate.MaxRounds)
	}
}

func TestSpawnCodeReviewDebateUsesConfigDefaultsWhenFlagsOmitted(t *testing.T) {
	setSpawnTestEnv(t)
	started := startDebateRuntimeCaptureForTest(t)
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".cerberus"), 0o755); err != nil {
		t.Fatalf("MkdirAll(.cerberus) error = %v", err)
	}
	configData := []byte(`version: 1
defaults:
  mode: max
  max_rounds: 5
roster:
  max:
    models:
      - provider: codex
        model: gpt
        effort: high
      - provider: claude
        model: opus
        effort: high
`)
	if err := os.WriteFile(filepath.Join(dir, ".cerberus", "config.yaml"), configData, 0o644); err != nil {
		t.Fatalf("WriteFile(config.yaml) error = %v", err)
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

	code := run([]string{"spawn-code-review", "--debate"}, &stdout, &stderr)

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

	code := run([]string{"spawn-code-review", "--mode", "unknown"}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("spawn-code-review exit code = 0, want non-zero")
	}
	events := readSpawnEventLog(t)
	event := findSpawnEvent(t, events, telemetry.EventPreflightFailed)
	if got, want := event["stage"], "config"; got != want {
		t.Fatalf("preflight failed stage = %v, want %q", got, want)
	}
	if !strings.Contains(event["error"].(string), `mode "unknown"`) {
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

	code := run([]string{"spawn-code-review"}, &stdout, &stderr)

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

func TestSpawnCodeReviewWarnsGenericHostNeedsManualWait(t *testing.T) {
	setSpawnTestEnv(t)
	startRuntimeInlineForTest(t, nil)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "review spawned") {
		t.Fatalf("stdout = %q, want review spawned", stdout.String())
	}
	for _, want := range []string{
		"CERBERUS_HOST=generic has no automatic Stop hook",
		`same cerberus binary with `,
		`wait --json --session-key "run"`,
		"same CERBERUS_STATE_ROOT and CERBERUS_PROJECT_KEY",
	} {
		if !strings.Contains(stderr.String(), want) {
			t.Fatalf("stderr = %q, want %q", stderr.String(), want)
		}
	}
	waitForSpawnGateStatus(t, state.StatusResolved)
}

func TestSpawnCodeReviewInfersCodexHostFromPluginRoot(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	home := t.TempDir()
	projectKey := "project"
	runKey := "codex-run"
	stateRoot := filepath.Join(home, ".codex", "projects", projectKey, "cerberus")
	if err := state.WriteSessionCache(state.SessionCachePath(stateRoot, projectKey), &state.SessionCache{
		Host:           "codex",
		ProjectKey:     projectKey,
		SessionID:      "codex-session",
		CodexSessionID: "codex-session",
		RunKey:         runKey,
		TranscriptPath: "/tmp/codex-session.jsonl",
	}); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}
	t.Setenv("PATH", spawnTestMockPath(t, repoRoot)+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("CERBERUS_STATE_ROOT", "")
	t.Setenv("CERBERUS_PROJECT_KEY", projectKey)
	t.Setenv("CERBERUS_RUN_KEY", "")
	t.Setenv("CERBERUS_SESSION_ID", "")
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
	t.Setenv("PLUGIN_ROOT", repoRoot)
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())
	startRuntimeInlineForTest(t, nil)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if strings.Contains(stderr.String(), "CERBERUS_HOST=generic") {
		t.Fatalf("stderr = %q, want codex inference without generic warning", stderr.String())
	}
	gate := waitForGateAtPath(t, state.GateStatePath(state.RunDir(stateRoot, projectKey, runKey)), state.StatusResolved)
	if gate.Host != "codex" || gate.RunKey != runKey || gate.ProjectKey != projectKey {
		t.Fatalf("gate = %#v, want codex host and cached run identity", gate)
	}
}

func TestSpawnCodeReviewInfersCodexHostAndProjectKeyFromCurrentRepo(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	home := t.TempDir()
	projectKey, err := host.ProjectKeyFromDir(repoRoot)
	if err != nil {
		t.Fatalf("ProjectKeyFromDir(repo root) error = %v", err)
	}
	runKey := "codex-derived-project-run"
	stateRoot := filepath.Join(home, ".codex", "projects", projectKey, "cerberus")
	if err := state.WriteSessionCache(state.SessionCachePath(stateRoot, projectKey), &state.SessionCache{
		Host:           "codex",
		ProjectKey:     projectKey,
		SessionID:      "codex-session",
		CodexSessionID: "codex-session",
		RunKey:         runKey,
		TranscriptPath: "/tmp/codex-session.jsonl",
	}); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}
	t.Setenv("PATH", spawnTestMockPath(t, repoRoot)+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("CERBERUS_STATE_ROOT", "")
	t.Setenv("CERBERUS_PROJECT_KEY", "")
	t.Setenv("CERBERUS_RUN_KEY", "")
	t.Setenv("CERBERUS_SESSION_ID", "")
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
	t.Setenv("PLUGIN_ROOT", repoRoot)
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())
	startRuntimeInlineForTest(t, nil)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if strings.Contains(stderr.String(), "CERBERUS_HOST=generic") {
		t.Fatalf("stderr = %q, want codex inference without generic warning", stderr.String())
	}
	gate := waitForGateAtPath(t, state.GateStatePath(state.RunDir(stateRoot, projectKey, runKey)), state.StatusResolved)
	if gate.Host != "codex" || gate.RunKey != runKey || gate.ProjectKey != projectKey {
		t.Fatalf("gate = %#v, want codex host and repo-derived project key", gate)
	}
}

func TestSpawnCodeReviewInfersClaudeHostFromClaudePluginRoot(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	home := t.TempDir()
	projectKey := "project"
	runKey := "claude-run"
	stateRoot := filepath.Join(home, ".claude", "projects", projectKey, "cerberus")
	if err := state.WriteSessionCache(state.SessionCachePath(stateRoot, projectKey), &state.SessionCache{
		Host:           "claude",
		ProjectKey:     projectKey,
		SessionID:      "claude-session",
		RunKey:         runKey,
		TranscriptPath: "/tmp/claude-session.jsonl",
	}); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}
	t.Setenv("PATH", spawnTestMockPath(t, repoRoot)+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("CERBERUS_STATE_ROOT", "")
	t.Setenv("CERBERUS_PROJECT_KEY", projectKey)
	t.Setenv("CERBERUS_RUN_KEY", "")
	t.Setenv("CERBERUS_SESSION_ID", "")
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", repoRoot)
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())
	startRuntimeInlineForTest(t, nil)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if strings.Contains(stderr.String(), "CERBERUS_HOST=generic") {
		t.Fatalf("stderr = %q, want claude inference without generic warning", stderr.String())
	}
	gate := waitForGateAtPath(t, state.GateStatePath(state.RunDir(stateRoot, projectKey, runKey)), state.StatusResolved)
	if gate.Host != "claude" || gate.RunKey != runKey || gate.ProjectKey != projectKey {
		t.Fatalf("gate = %#v, want claude host and cached run identity", gate)
	}
}

func TestSpawnCodeReviewInfersClaudeHostAndProjectKeyFromCurrentRepo(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	home := t.TempDir()
	projectKey, err := host.ProjectKeyFromDir(repoRoot)
	if err != nil {
		t.Fatalf("ProjectKeyFromDir(repo root) error = %v", err)
	}
	runKey := "claude-derived-project-run"
	stateRoot := filepath.Join(home, ".claude", "projects", projectKey, "cerberus")
	if err := state.WriteSessionCache(state.SessionCachePath(stateRoot, projectKey), &state.SessionCache{
		Host:           "claude",
		ProjectKey:     projectKey,
		SessionID:      "claude-session",
		RunKey:         runKey,
		TranscriptPath: "/tmp/claude-session.jsonl",
	}); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}
	t.Setenv("PATH", spawnTestMockPath(t, repoRoot)+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("CERBERUS_STATE_ROOT", "")
	t.Setenv("CERBERUS_PROJECT_KEY", "")
	t.Setenv("CERBERUS_RUN_KEY", "")
	t.Setenv("CERBERUS_SESSION_ID", "")
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", repoRoot)
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())
	startRuntimeInlineForTest(t, nil)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if strings.Contains(stderr.String(), "CERBERUS_HOST=generic") {
		t.Fatalf("stderr = %q, want claude inference without generic warning", stderr.String())
	}
	gate := waitForGateAtPath(t, state.GateStatePath(state.RunDir(stateRoot, projectKey, runKey)), state.StatusResolved)
	if gate.Host != "claude" || gate.RunKey != runKey || gate.ProjectKey != projectKey {
		t.Fatalf("gate = %#v, want claude host and repo-derived project key", gate)
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

	code := run([]string{"spawn-code-review"}, &stdout, &stderr)

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

func TestSinglePassReviewerFailureResolvesPendingGate(t *testing.T) {
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

	if code != 0 {
		t.Fatalf("runSinglePassRuntime exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	gate := readSpawnGate(t)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictRequiresDecision {
		t.Fatalf("gate verdict = %v, want requires_decision", gate.Verdict)
	}
	if !strings.Contains(gate.ResolutionReason, "1 reviewer failed") {
		t.Fatalf("resolution reason = %q, want reviewer failure", gate.ResolutionReason)
	}
	events := readSpawnEventLog(t)
	findSpawnEvent(t, events, telemetry.EventRuntimeStarted)
	findSpawnEvent(t, events, telemetry.EventRuntimeCompleted)
	findSpawnEvent(t, events, telemetry.EventReviewerProcessLaunching)
	findSpawnEvent(t, events, telemetry.EventReviewerProcessStarted)
	findSpawnEvent(t, events, telemetry.EventReviewerProcessFailed)
	findSpawnEvent(t, events, telemetry.EventReviewerFailed)
	if err := hook.PollGateState(spawnGatePath(), 10*time.Millisecond, time.Second); err != nil {
		t.Fatalf("PollGateState() error = %v", err)
	}
}

func TestSinglePassRuntimeSuccessRecordsLifecycleEvents(t *testing.T) {
	setSpawnTestEnv(t)
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

	if code != 0 {
		t.Fatalf("runSinglePassRuntime exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	gate := readSpawnGate(t)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	events := readSpawnEventLog(t)
	findSpawnEvent(t, events, telemetry.EventRuntimeStarted)
	findSpawnEvent(t, events, telemetry.EventRuntimeCompleted)
	findSpawnEvent(t, events, telemetry.EventReviewerProcessLaunching)
	findSpawnEvent(t, events, telemetry.EventReviewerProcessStarted)
	findSpawnEvent(t, events, telemetry.EventReviewerProcessCompleted)
}

func TestStartRuntimeProcessRecordsLaunchEvents(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows explicitly blocks detached runtime launch")
	}
	setSpawnTestEnv(t)
	started, err := orchestrator.StartSinglePass(nil, orchestrator.Params{
		Prompt: []byte("review this"),
		Reviewers: []orchestrator.ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	})
	if err != nil {
		t.Fatalf("StartSinglePass() error = %v", err)
	}
	fakeRuntime := filepath.Join(t.TempDir(), "fake-runtime")
	if err := os.WriteFile(fakeRuntime, []byte("#!/bin/sh\necho fake runtime $1\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("WriteFile(fake runtime) error = %v", err)
	}
	oldExecutable := runtimeExecutable
	runtimeExecutable = func() (string, error) { return fakeRuntime, nil }
	t.Cleanup(func() { runtimeExecutable = oldExecutable })
	requestPath := filepath.Join(started.RunRoot, "single-pass-request.json")

	if err := startRuntimeProcess(started, requestPath, "run-single-pass", "single-pass"); err != nil {
		t.Fatalf("startRuntimeProcess() error = %v", err)
	}

	events := readSpawnEventLog(t)
	launching := findSpawnEvent(t, events, telemetry.EventRuntimeLaunching)
	launched := findSpawnEvent(t, events, telemetry.EventRuntimeLaunched)
	if launching["request_path"] != requestPath || launched["request_path"] != requestPath {
		t.Fatalf("runtime launch events request_path = %v / %v, want %q", launching["request_path"], launched["request_path"], requestPath)
	}
	if _, ok := launched["pid"]; !ok {
		t.Fatalf("runtime launched event missing pid: %#v", launched)
	}
}

func TestDebateReviewerFailureResolvesPendingGate(t *testing.T) {
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

	if code != 0 {
		t.Fatalf("runDebateRuntime exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	gate := readSpawnGate(t)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictRequiresDecision {
		t.Fatalf("gate verdict = %v, want requires_decision", gate.Verdict)
	}
	if !strings.Contains(gate.ResolutionReason, "debate degraded below 2 active reviewers") {
		t.Fatalf("resolution reason = %q, want degraded active reviewer count", gate.ResolutionReason)
	}
	if err := hook.PollGateState(spawnGatePath(), 10*time.Millisecond, time.Second); err != nil {
		t.Fatalf("PollGateState() error = %v", err)
	}
}

func TestParseSpawnCodeReviewPreservesExplicitModeAndMaxRounds(t *testing.T) {
	var stderr bytes.Buffer

	opts, err := parseSpawnCodeReviewFlags([]string{"--mode", "smart", "--max-rounds", "5", "--fail-priority", "p2"}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags() error = %v", err)
	}
	if opts.mode != "smart" || opts.maxRounds != 5 {
		t.Fatalf("mode/maxRounds = %q/%d, want smart/5", opts.mode, opts.maxRounds)
	}
	if opts.failurePriority != 2 {
		t.Fatalf("failurePriority = %d, want 2", opts.failurePriority)
	}
}

func TestParseSpawnCodeReviewTranslatesZeroMaxRoundsToSingleIteration(t *testing.T) {
	var stderr bytes.Buffer

	opts, err := parseSpawnCodeReviewFlags([]string{"--max-rounds", "0"}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags() error = %v", err)
	}
	if !opts.maxRoundsSet || opts.maxRounds != 0 {
		t.Fatalf("parsed max rounds = set:%t value:%d, want explicit zero", opts.maxRoundsSet, opts.maxRounds)
	}
	if got := opts.explicitMaxRounds(); got != 1 {
		t.Fatalf("explicitMaxRounds() = %d, want 1", got)
	}
}

func TestParseSpawnCodeReviewPostReviewer(t *testing.T) {
	var stderr bytes.Buffer

	opts, err := parseSpawnCodeReviewFlags([]string{}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags(default) error = %v", err)
	}
	defaultSlot := opts.postReviewSlot()
	if defaultSlot.Provider != "codex" || defaultSlot.Model != "gpt-5.6-sol" || defaultSlot.Effort != "low" {
		t.Fatalf("default post reviewer = %#v, want codex/gpt-5.6-sol/low", defaultSlot)
	}

	opts, err = parseSpawnCodeReviewFlags([]string{"--post-reviewer", "claude:opus:high"}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags(custom) error = %v", err)
	}
	slot := opts.postReviewSlot()
	if slot.Provider != "claude" || slot.Model != "opus" || slot.Effort != "high" {
		t.Fatalf("custom post reviewer = %#v, want claude/opus/high", slot)
	}

	opts, err = parseSpawnCodeReviewFlags([]string{"--post-reviewer", "codex:gpt:max"}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags(max effort) error = %v", err)
	}
	slot = opts.postReviewSlot()
	if slot.Provider != "codex" || slot.Model != "gpt" || slot.Effort != "max" {
		t.Fatalf("max-effort post reviewer = %#v, want codex/gpt/max", slot)
	}

	opts, err = parseSpawnCodeReviewFlags([]string{"--post-reviewer", "gemini:pro:xhigh"}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags(xhigh effort) error = %v", err)
	}
	slot = opts.postReviewSlot()
	if slot.Provider != "gemini" || slot.Model != "pro" || slot.Effort != "xhigh" {
		t.Fatalf("xhigh-effort post reviewer = %#v, want gemini/pro/xhigh", slot)
	}

	_, err = parseSpawnCodeReviewFlags([]string{"--post-reviewer", "codex:gpt:turbo"}, &stderr)
	if err == nil || !strings.Contains(err.Error(), "--post-reviewer effort") {
		t.Fatalf("invalid post reviewer error = %v, want effort error", err)
	}
}

func TestNormalizeEpicVerifyArgsRecognizesFailPriority(t *testing.T) {
	got, err := normalizeReviewArgs([]string{"--fail-priority", "p2", "docs/epic.md"}, "epic-verify")
	if err != nil {
		t.Fatalf("normalizeReviewArgs() error = %v", err)
	}
	want := []string{"--fail-priority", "p2", "--", "docs/epic.md"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("normalizeReviewArgs() = %#v, want %#v", got, want)
	}

	got, err = normalizeReviewArgs([]string{"--fail-priority=p2", "docs/epic.md"}, "epic-verify")
	if err != nil {
		t.Fatalf("normalizeReviewArgs(equals) error = %v", err)
	}
	want = []string{"--fail-priority=p2", "--", "docs/epic.md"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("normalizeReviewArgs(equals) = %#v, want %#v", got, want)
	}

	got, err = normalizeReviewArgs([]string{"--post-reviewer", "claude:opus:high", "docs/epic.md"}, "epic-verify")
	if err != nil {
		t.Fatalf("normalizeReviewArgs(post-reviewer) error = %v", err)
	}
	want = []string{"--post-reviewer", "claude:opus:high", "--", "docs/epic.md"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("normalizeReviewArgs(post-reviewer) = %#v, want %#v", got, want)
	}
}

func TestParseSpawnCodeReviewRejectsExplicitInvalidRuntimeFlags(t *testing.T) {
	var stderr bytes.Buffer

	_, err := parseSpawnCodeReviewFlags([]string{"--max-rounds", "-1"}, &stderr)
	if err == nil || !strings.Contains(err.Error(), "--max-rounds must be non-negative") {
		t.Fatalf("negative max-rounds error = %v, want non-negative error", err)
	}

	_, err = parseSpawnCodeReviewFlags([]string{"--mode", ""}, &stderr)
	if err == nil || !strings.Contains(err.Error(), "--mode must not be empty") {
		t.Fatalf("empty mode error = %v, want non-empty mode error", err)
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

func TestResolveReviewersCarriesConfigDefaultsAndModelEffort(t *testing.T) {
	setSpawnTestEnv(t)
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".cerberus"), 0o755); err != nil {
		t.Fatalf("MkdirAll(.cerberus) error = %v", err)
	}
	configData := []byte(`version: 1
defaults:
  mode: deep-review
  max_rounds: 3
roster:
  deep-review:
    models:
      - provider: codex
        model: gpt
        effort: high
`)
	if err := os.WriteFile(filepath.Join(dir, ".cerberus", "config.yaml"), configData, 0o644); err != nil {
		t.Fatalf("WriteFile(config.yaml) error = %v", err)
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
	if resolved.defaults.Mode != "deep-review" || resolved.defaults.MaxRounds != 3 {
		t.Fatalf("defaults = %#v, want mode deep-review max_rounds 3", resolved.defaults)
	}
	if got, want := resolved.reviewers[0].Effort, "high"; got != want {
		t.Fatalf("reviewer effort = %q, want %q", got, want)
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
		Mode:             "smart",
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
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
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
	configData := []byte("version: 1\nroster:\n  smart:\n    models:\n      - provider: codex\n        model: gpt\n        effort: medium\n")
	if err := os.WriteFile(filepath.Join(dir, ".cerberus", "config.yaml"), configData, 0o644); err != nil {
		t.Fatalf("WriteFile(config.yaml) error = %v", err)
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
	return waitForGateAtPath(t, spawnGatePath(), want)
}

func waitForGateAtPath(t *testing.T, path, want string) *state.GateState {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	var last *state.GateState
	for time.Now().Before(deadline) {
		gate, err := state.ReadGateState(path)
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
	if provider == "gemini" {
		if !strings.Contains(string(data), "--model\ncerberus-reviewer\n") {
			t.Fatalf("gemini args = %q, want effort model alias", string(data))
		}
		settings, err := os.ReadFile(filepath.Join(os.Getenv("CERBERUS_MOCK_RECORD_DIR"), provider+".settings.json"))
		if err != nil {
			t.Fatalf("ReadFile(%s.settings.json) error = %v", provider, err)
		}
		if !strings.Contains(string(settings), `"model": "`+want+`"`) {
			t.Fatalf("gemini settings = %q, want model %q", settings, want)
		}
		return
	}
	if !strings.Contains(string(data), "--model\n"+want+"\n") {
		t.Fatalf("%s args = %q, want model %q", provider, string(data), want)
	}
	if strings.Contains(string(data), "--model\n"+provider+"\n") {
		t.Fatalf("%s args = %q, must not use provider name as model", provider, string(data))
	}
}

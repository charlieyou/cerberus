package orchestrator

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/aggregate"
	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/state"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

func TestRunSinglePassTransitionsPendingToResolvedPass(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := observingSpawner{t: t, env: env}

	if err := RunSinglePass(context.Background(), env, testParams(), spawner); err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}

	gate := readGate(t, env)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.StatusResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictPass {
		t.Fatalf("gate verdict = %v, want %q", gate.Verdict, state.VerdictPass)
	}
}

func TestRunSinglePassAllReviewersFailedResolvesRequiresDecision(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	wantErr := errors.New("reviewer failed")

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, errorSpawner{err: wantErr})
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v, want nil", err)
	}

	gate := readGate(t, env)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.StatusResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictRequiresDecision {
		t.Fatalf("gate verdict = %v, want %q", gate.Verdict, state.VerdictRequiresDecision)
	}
	if !strings.Contains(gate.ResolutionReason, "1 reviewer failed") {
		t.Fatalf("resolution reason = %q, want reviewer failure", gate.ResolutionReason)
	}

	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	failed := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "codex#1", "output.json"))
	if _, ok := failed["summary"]; ok {
		t.Fatalf("failed output summary = %v, want omitted", failed["summary"])
	}
	events := readEventLog(t, env)
	assertEventCount(t, events, telemetry.EventReviewerFailed, 1)
}

func TestStartSinglePassPreflightsDefaultPostReviewer(t *testing.T) {
	env := testEnv(t)
	providerDir := t.TempDir()
	writeFakeProvider(t, providerDir, "claude")
	t.Setenv("PATH", providerDir)

	_, err := StartSinglePass(env, Params{
		Prompt:       []byte("review this"),
		ArtifactType: "code",
		Reviewers: []ReviewerSlot{
			{ID: "claude#1", Provider: "claude", Model: "stub"},
		},
	})
	if err == nil || !strings.Contains(err.Error(), `post-reviewer preflight: provider CLI "codex" is not available on PATH`) {
		t.Fatalf("StartSinglePass() error = %v, want missing default post-reviewer codex preflight", err)
	}
	gatePath := state.GateStatePath(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey))
	if _, statErr := os.Stat(gatePath); !os.IsNotExist(statErr) {
		t.Fatalf("gate state stat err = %v, want no pending gate created", statErr)
	}
}

func TestStartSinglePassDefaultsPostReviewerModelForSelectedProvider(t *testing.T) {
	env := testEnv(t)
	providerDir := t.TempDir()
	writeFakeProvider(t, providerDir, "claude")
	t.Setenv("PATH", providerDir)

	started, err := StartSinglePass(env, Params{
		Prompt:       []byte("review this"),
		ArtifactType: "code",
		PostReviewer: ReviewerSlot{
			Provider: "claude",
		},
		Reviewers: []ReviewerSlot{
			{ID: "claude#1", Provider: "claude", Model: "stub"},
		},
	})
	if err != nil {
		t.Fatalf("StartSinglePass() error = %v", err)
	}
	if started.Params.PostReviewer.Provider != "claude" || started.Params.PostReviewer.Model != "opus" || started.Params.PostReviewer.Mode != "fast" {
		t.Fatalf("post reviewer = %#v, want claude provider default model and fast mode", started.Params.PostReviewer)
	}
}

func TestRunSinglePassMajorityPassFailTieWithReviewerFailureResolvesFail(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)

	err := RunSinglePass(context.Background(), env, Params{
		Prompt:    []byte("review this"),
		Consensus: aggregate.ModeMajority,
		Reviewers: []ReviewerSlot{
			{ID: "claude#1", Provider: "claude", Model: "stub"},
			{ID: "codex#1", Provider: "codex", Model: "stub"},
			{ID: "gemini#1", Provider: "gemini", Model: "stub"},
		},
	}, mixedVerdictFailureSpawner{
		failures: map[string]error{"gemini#1": errors.New("auth unavailable")},
		verdicts: map[string]string{
			"claude#1": "PASS",
			"codex#1":  "FAIL",
		},
	})
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v, want nil", err)
	}

	gate := readGate(t, env)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.StatusResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictFail {
		t.Fatalf("gate verdict = %v, want %q", gate.Verdict, state.VerdictFail)
	}
	if !strings.Contains(gate.ResolutionReason, "1 reviewer failed") {
		t.Fatalf("resolution reason = %q, want reviewer failure", gate.ResolutionReason)
	}
}

func TestRunSinglePassNonFailingFindingsPassByDefault(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, needsWorkSpawner{})
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}

	gate := readGate(t, env)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.StatusResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictPass {
		t.Fatalf("gate verdict = %v, want %q", gate.Verdict, state.VerdictPass)
	}
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	row := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "codex#1", "telemetry.json"))
	if row["verdict"] != state.VerdictPass {
		t.Fatalf("reviewer telemetry verdict = %v, want %q", row["verdict"], state.VerdictPass)
	}
}

func TestRunSinglePassRunsPostReviewDedupAgentForDuplicateCodeFindings(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := &dedupRecordingSpawner{dedupDelay: 20 * time.Millisecond}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt:          []byte("review this"),
		ArtifactType:    "code",
		ArtifactContent: "diff body for verification",
		ContextContent:  "author context for verification",
		Reviewers: []ReviewerSlot{
			{ID: "claude#1", Provider: "claude", Model: "stub"},
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}

	if !spawner.dedupCalled {
		t.Fatal("post-review dedup agent was not called")
	}
	if spawner.dedupProvider != "codex" || spawner.dedupModel != "gpt-5.5" || spawner.dedupMode != "fast" {
		t.Fatalf("dedup slot = %s/%s/%s, want codex/gpt-5.5/fast", spawner.dedupProvider, spawner.dedupModel, spawner.dedupMode)
	}
	if !strings.Contains(spawner.dedupPrompt, "claude#1") || !strings.Contains(spawner.dedupPrompt, "codex#1") || !strings.Contains(spawner.dedupPrompt, "duplicate bug") {
		t.Fatalf("dedup prompt = %q, want original reviewer findings", spawner.dedupPrompt)
	}
	for _, want := range []string{"diff body for verification", "author context for verification", "review this", `"failure_priority": 1`} {
		if !strings.Contains(spawner.dedupPrompt, want) {
			t.Fatalf("dedup prompt = %q, want %q", spawner.dedupPrompt, want)
		}
	}
	gate := readGate(t, env)
	if gate.Verdict == nil || *gate.Verdict != state.VerdictPass {
		t.Fatalf("gate verdict = %v, want deduped pass", gate.Verdict)
	}
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	output := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "round-99", "reviewers", "cerberus-dedup#1", "output.json"))
	if findings, ok := output["findings"].([]any); !ok || len(findings) != 0 {
		t.Fatalf("dedup output findings = %#v, want empty deduped output", output["findings"])
	}
	iteration := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "iteration-telemetry.json"))
	summary, ok := iteration["reviewer_summary"].([]any)
	if !ok || len(summary) != 1 {
		t.Fatalf("reviewer summary = %#v, want one post-review summary", iteration["reviewer_summary"])
	}
	entry, ok := summary[0].(map[string]any)
	if !ok || entry["reviewer_id"] != "cerberus-dedup#1" || entry["verdict"] != state.VerdictPass {
		t.Fatalf("reviewer summary = %#v, want dedup pass summary", summary[0])
	}
	dedupTelemetry := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "round-99", "reviewers", "cerberus-dedup#1", "telemetry.json"))
	dedupEndedAt, err := time.Parse(time.RFC3339Nano, fmt.Sprint(dedupTelemetry["ended_at"]))
	if err != nil {
		t.Fatalf("parse dedup ended_at: %v", err)
	}
	gate = readGate(t, env)
	if gate.EndedAt == nil || gate.EndedAt.Before(dedupEndedAt) {
		t.Fatalf("gate ended_at = %v, want after dedup ended_at %v", gate.EndedAt, dedupEndedAt)
	}
}

func TestRunSinglePassPostReviewDedupReceivesEpicVerificationContext(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := &dedupRecordingSpawner{}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt:          []byte("verify epic"),
		ArtifactType:    "epic-verify",
		ArtifactContent: "epic acceptance criteria",
		ContextContent:  "implementation context",
		Reviewers: []ReviewerSlot{
			{ID: "claude#1", Provider: "claude", Model: "stub"},
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}
	if !spawner.dedupCalled {
		t.Fatal("post-review dedup agent was not called")
	}
	for _, want := range []string{"epic-verify", "epic acceptance criteria", "implementation context", "verify epic"} {
		if !strings.Contains(spawner.dedupPrompt, want) {
			t.Fatalf("dedup prompt = %q, want %q", spawner.dedupPrompt, want)
		}
	}
}

func TestRunSinglePassUsesConfiguredPostReviewDedupSlot(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := &dedupRecordingSpawner{}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt:       []byte("review this"),
		ArtifactType: "code",
		PostReviewer: ReviewerSlot{
			Provider: "claude",
			Model:    "claude-opus-test",
			Mode:     "max",
		},
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
			{ID: "gemini#1", Provider: "gemini", Model: "stub"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}
	if spawner.dedupProvider != "claude" || spawner.dedupModel != "claude-opus-test" || spawner.dedupMode != "max" {
		t.Fatalf("dedup slot = %s/%s/%s, want configured claude/claude-opus-test/max", spawner.dedupProvider, spawner.dedupModel, spawner.dedupMode)
	}
}

func TestRunSinglePassPostReviewDedupCanRetainBlockingFinding(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	priority := 1
	severity := "blocking"
	spawner := &dedupRecordingSpawner{dedupFindings: []reviewer.RawFinding{{
		Title:    "retained blocker",
		Body:     "dedup kept the blocking source finding",
		Priority: &priority,
		Severity: &severity,
	}}}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt:       []byte("review this"),
		ArtifactType: "code",
		Reviewers: []ReviewerSlot{
			{ID: "claude#1", Provider: "claude", Model: "stub"},
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}
	gate := readGate(t, env)
	if gate.Verdict == nil || *gate.Verdict != state.VerdictFail {
		t.Fatalf("gate verdict = %v, want retained dedup blocker to fail", gate.Verdict)
	}
}

func TestStartSinglePassTelemetryFailureResolvesGate(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	if err := os.MkdirAll(filepath.Join(runRoot, "event-log.jsonl"), 0o755); err != nil {
		t.Fatalf("MkdirAll(event-log.jsonl) error = %v", err)
	}

	_, err := StartSinglePass(env, testParams())

	if err == nil || !strings.Contains(err.Error(), "open event log") {
		t.Fatalf("StartSinglePass() error = %v, want open event log", err)
	}
	gate := readGate(t, env)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.StatusResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictRequiresDecision {
		t.Fatalf("gate verdict = %v, want %q", gate.Verdict, state.VerdictRequiresDecision)
	}
	if !strings.Contains(gate.ResolutionReason, "roster selected telemetry failed") {
		t.Fatalf("resolution reason = %q, want telemetry failure", gate.ResolutionReason)
	}
}

func TestStartSinglePassFallsBackToCodexSessionCache(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	env.Host = "codex"
	env.RunKey = ""
	env.SessionID = ""
	env.TranscriptPath = ""
	if err := state.WriteSessionCache(state.SessionCachePath(env.StateRoot, env.ProjectKey), &state.SessionCache{
		Host:           "codex",
		ProjectKey:     env.ProjectKey,
		SessionID:      "codex-session",
		CodexSessionID: "codex-session",
		RunKey:         "codex-run",
		TranscriptPath: "/tmp/codex-session.jsonl",
	}); err != nil {
		t.Fatalf("WriteSessionCache() error = %v", err)
	}

	started, err := StartSinglePass(env, testParams())
	if err != nil {
		t.Fatalf("StartSinglePass() error = %v", err)
	}

	if started.Env.RunKey != "codex-run" || started.Env.SessionID != "codex-session" || started.Env.TranscriptPath != "/tmp/codex-session.jsonl" {
		t.Fatalf("started env = %#v, want identity from session cache", started.Env)
	}
	if _, err := os.Stat(state.GateStatePath(state.RunDir(env.StateRoot, env.ProjectKey, "codex-run"))); err != nil {
		t.Fatalf("cached run gate state missing: %v", err)
	}
}

func TestStartSinglePassCodexWithoutSessionCacheExplainsHookSetup(t *testing.T) {
	env := testEnv(t)
	env.Host = "codex"
	env.RunKey = ""
	env.SessionID = ""

	_, err := StartSinglePass(env, testParams())

	if err == nil {
		t.Fatal("StartSinglePass() error = nil, want missing Codex hook setup error")
	}
	for _, want := range []string{"Codex Cerberus hooks have not initialized", "/hooks", "CERBERUS_RUN_KEY"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("StartSinglePass() error = %q, want %q", err, want)
		}
	}
}

func TestStartSinglePassClaudeWithoutSessionCacheExplainsHookSetup(t *testing.T) {
	env := testEnv(t)
	env.Host = "claude"
	env.RunKey = ""
	env.SessionID = ""

	_, err := StartSinglePass(env, testParams())

	if err == nil {
		t.Fatal("StartSinglePass() error = nil, want missing Claude hook setup error")
	}
	for _, want := range []string{"Claude Cerberus hooks have not initialized", "restart Claude Code", "CERBERUS_RUN_KEY"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("StartSinglePass() error = %q, want %q", err, want)
		}
	}
}

func TestRunSinglePassRejectsWhenExistingGateIsPending(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	path := gatePath(env)
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	if err := state.WriteGateState(path, &state.GateState{
		RunKey:           env.RunKey,
		Host:             env.Host,
		ProjectKey:       env.ProjectKey,
		Status:           state.StatusPending,
		CurrentIteration: 1,
		MaxRounds:        1,
		RosterID:         "default",
	}); err != nil {
		t.Fatalf("seed gate state: %v", err)
	}
	if err := state.WriteReviewerOutput(runRoot, 1, 1, "old#1", []byte(`{"findings":[]}`)); err != nil {
		t.Fatalf("WriteReviewerOutput() error = %v", err)
	}

	err := RunSinglePass(context.Background(), env, testParams(), passSpawner{})

	if err == nil || !strings.Contains(err.Error(), "review already pending") || !strings.Contains(err.Error(), env.RunKey) {
		t.Fatalf("RunSinglePass() error = %v, want pending gate rejection", err)
	}
	gate := readGate(t, env)
	if gate.Status != state.StatusPending || gate.EndedAt != nil {
		t.Fatalf("gate = %#v, want original pending gate", gate)
	}
	if _, statErr := os.Stat(filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "old#1", "output.json")); statErr != nil {
		t.Fatalf("stale reviewer artifact stat err = %v, want not reset", statErr)
	}
	events := readEventLog(t, env)
	assertEventCount(t, events, telemetry.EventReviewSpawned, 0)
	failure := findEvent(t, events, telemetry.EventPreflightFailed)
	if failure["reason"] != "pending_gate" {
		t.Fatalf("preflight failure event = %#v, want pending_gate reason", failure)
	}
}

func TestStartSinglePassFailsClosedWhenGateStateUnreadable(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	if err := state.EnsureRunDir(runRoot); err != nil {
		t.Fatalf("EnsureRunDir() error = %v", err)
	}
	if err := os.WriteFile(gatePath(env), []byte(`{"status":`), 0o644); err != nil {
		t.Fatalf("write corrupt gate state: %v", err)
	}
	if err := state.WriteReviewerOutput(runRoot, 1, 1, "old#1", []byte(`{"findings":[]}`)); err != nil {
		t.Fatalf("WriteReviewerOutput() error = %v", err)
	}

	_, err := StartSinglePass(env, testParams())

	if err == nil || !strings.Contains(err.Error(), "unmarshal gate state") {
		t.Fatalf("StartSinglePass() error = %v, want unreadable gate state error", err)
	}
	if _, statErr := os.Stat(filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "old#1", "output.json")); statErr != nil {
		t.Fatalf("stale reviewer artifact stat err = %v, want not reset", statErr)
	}
}

func TestStartSinglePassRejectsConcurrentStartLock(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	if err := state.EnsureRunDir(runRoot); err != nil {
		t.Fatalf("EnsureRunDir() error = %v", err)
	}
	if err := os.WriteFile(state.StartLockPath(runRoot), []byte("locked\n"), 0o644); err != nil {
		t.Fatalf("write start lock: %v", err)
	}

	_, err := StartSinglePass(env, testParams())

	if err == nil || !strings.Contains(err.Error(), "review start already in progress") || !strings.Contains(err.Error(), env.RunKey) {
		t.Fatalf("StartSinglePass() error = %v, want start lock rejection", err)
	}
	events := readEventLog(t, env)
	failure := findEvent(t, events, telemetry.EventPreflightFailed)
	if failure["reason"] != "start_lock" {
		t.Fatalf("preflight failure event = %#v, want start_lock reason", failure)
	}
}

func TestStartSinglePassResetsAttemptScopedArtifacts(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	if err := os.MkdirAll(runRoot, 0o755); err != nil {
		t.Fatalf("MkdirAll(runRoot) error = %v", err)
	}
	if err := os.WriteFile(state.StopMessageMarkerPath(runRoot), []byte(`{"emitted_at":"old"}`), 0o644); err != nil {
		t.Fatalf("write marker: %v", err)
	}
	if err := state.WriteReviewerOutput(runRoot, 1, 1, "old#1", []byte(`{"findings":[]}`)); err != nil {
		t.Fatalf("WriteReviewerOutput() error = %v", err)
	}

	if _, err := StartSinglePass(env, testParams()); err != nil {
		t.Fatalf("StartSinglePass() error = %v", err)
	}
	if _, err := os.Stat(state.StopMessageMarkerPath(runRoot)); !os.IsNotExist(err) {
		t.Fatalf("marker stat err = %v, want marker removed", err)
	}
	if _, err := os.Stat(state.IterationsDir(runRoot)); !os.IsNotExist(err) {
		t.Fatalf("iterations stat err = %v, want previous iterations removed", err)
	}
}

func TestRunSinglePassUsesRosterDefaultsWhenParamsOmitted(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := modeSpawner{want: "max"}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt:         []byte("review this"),
		RosterDefaults: RosterDefaults{Mode: "max", MaxRounds: 3},
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}

	gate := readGate(t, env)
	if gate.MaxRounds != 3 {
		t.Fatalf("gate max_rounds = %d, want 3", gate.MaxRounds)
	}
	if gate.Mode != "max" {
		t.Fatalf("gate mode = %q, want max", gate.Mode)
	}
	runTelemetry := readRunTelemetry(t, env)
	if got, want := runTelemetry["mode"], "max"; got != want {
		t.Fatalf("run telemetry mode = %v, want %q", got, want)
	}
}

func TestRunSinglePassCLIParamsOverrideRosterDefaults(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := modeSpawner{want: "smart"}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt:         []byte("review this"),
		RosterDefaults: RosterDefaults{Mode: "max", MaxRounds: 3},
		Mode:           "smart",
		MaxRounds:      1,
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}

	gate := readGate(t, env)
	if gate.MaxRounds != 1 {
		t.Fatalf("gate max_rounds = %d, want 1", gate.MaxRounds)
	}
	if gate.Mode != "" {
		t.Fatalf("gate mode = %q, want empty for non-max", gate.Mode)
	}
	runTelemetry := readRunTelemetry(t, env)
	if got, want := runTelemetry["mode"], "smart"; got != want {
		t.Fatalf("run telemetry mode = %v, want %q", got, want)
	}
}

func TestRunSinglePassWritesReviewerRoundAndIterationTelemetry(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := usageSpawner{}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Mode:   "smart",
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "gpt-5.4", Strategy: "falsification-first", InstanceIndex: 1},
			{ID: "claude#2", Provider: "claude", Model: "sonnet", InstanceIndex: 2},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}

	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	row := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "codex#1", "telemetry.json"))
	if got, want := row["reviewer_id"], "codex#1"; got != want {
		t.Fatalf("reviewer_id = %v, want %q", got, want)
	}
	if got, want := row["instance_index"], float64(1); got != want {
		t.Fatalf("instance_index = %v, want %v", got, want)
	}
	if got := row["persona_name"]; got != nil {
		t.Fatalf("persona_name = %v, want nil", got)
	}
	tokens := row["tokens"].(map[string]any)
	if got, want := tokens["input"], float64(10); got != want {
		t.Fatalf("tokens.input = %v, want %v", got, want)
	}
	if got, want := row["cost_usd"], 0.01; got != want {
		t.Fatalf("cost_usd = %v, want %v", got, want)
	}

	roundTelemetry := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "round-1", "round-telemetry.json"))
	if got, want := roundTelemetry["reviewer_count"], float64(2); got != want {
		t.Fatalf("round reviewer_count = %v, want %v", got, want)
	}
	if got, want := roundTelemetry["consensus_pct"], float64(1); got != want {
		t.Fatalf("round consensus_pct = %v, want %v", got, want)
	}

	iterationTelemetry := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "iteration-telemetry.json"))
	summary := iterationTelemetry["reviewer_summary"].([]any)
	if len(summary) != 2 {
		t.Fatalf("reviewer_summary length = %d, want 2", len(summary))
	}
	runTelemetry := readRunTelemetry(t, env)
	totalTokens := runTelemetry["total_tokens"].(map[string]any)
	if got, want := totalTokens["input"], float64(30); got != want {
		t.Fatalf("run total_tokens.input = %v, want %v", got, want)
	}
	if got, want := runTelemetry["total_cost_usd"], 0.03; got != want {
		t.Fatalf("run total_cost_usd = %v, want %v", got, want)
	}

	events := readEventLog(t, env)
	assertEventCount(t, events, telemetry.EventReviewSpawned, 1)
	assertEventCount(t, events, telemetry.EventRosterSelected, 1)
	assertEventCount(t, events, telemetry.EventReviewerSpawned, 2)
	assertEventCount(t, events, telemetry.EventReviewerCompleted, 2)
	assertEventCount(t, events, telemetry.EventReviewRoundComplete, 1)
	assertEventCount(t, events, telemetry.EventReviewResolved, 1)
	rosterEvent := findEvent(t, events, telemetry.EventRosterSelected)
	if got, want := rosterEvent["roster_name"], "default"; got != want {
		t.Fatalf("roster selected roster_name = %v, want %q", got, want)
	}
	if got, want := rosterEvent["reviewer_count"], float64(2); got != want {
		t.Fatalf("roster selected reviewer_count = %v, want %v", got, want)
	}
	for _, event := range events {
		if event["event"] != telemetry.EventReviewerSpawned && event["event"] != telemetry.EventReviewerCompleted {
			continue
		}
		switch event["reviewer_id"] {
		case "codex#1", "claude#2":
		default:
			t.Fatalf("reviewer event reviewer_id = %v, want codex#1 or claude#2", event["reviewer_id"])
		}
		if event["instance_index"] != float64(1) && event["instance_index"] != float64(2) {
			t.Fatalf("reviewer event instance_index = %v, want 1 or 2", event["instance_index"])
		}
	}
	roundEvent := findEvent(t, events, telemetry.EventReviewRoundComplete)
	if got, want := roundEvent["round"], float64(1); got != want {
		t.Fatalf("round_complete round = %v, want %v", got, want)
	}
	if got, want := roundEvent["consensus_pct"], float64(1); got != want {
		t.Fatalf("round_complete consensus_pct = %v, want %v", got, want)
	}
	if got, want := roundEvent["abstentions"], float64(0); got != want {
		t.Fatalf("round_complete abstentions = %v, want %v", got, want)
	}
}

func TestRunSinglePassSlotModeOverridesRuntimeModeForReviewer(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := modeSpawner{want: "fast"}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt:         []byte("review this"),
		RosterDefaults: RosterDefaults{Mode: "max"},
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub", Mode: "fast"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}
}

func TestRunSinglePassExplicitMissingCLIFailsBeforePendingGate(t *testing.T) {
	env := testEnv(t)
	t.Setenv("PATH", t.TempDir())

	err := RunSinglePass(context.Background(), env, testParams(), passSpawner{})
	if err == nil {
		t.Fatal("RunSinglePass() error = nil, want missing CLI preflight error")
	}
	if !strings.Contains(err.Error(), `provider CLI "claude" is not available on PATH`) {
		t.Fatalf("RunSinglePass() error = %q, want missing CLI preflight", err)
	}
	if _, err := state.ReadGateState(gatePath(env)); err == nil {
		t.Fatal("gate-state.json exists after preflight failure, want no pending gate")
	}
	events := readEventLog(t, env)
	event := findEvent(t, events, telemetry.EventPreflightFailed)
	if got, want := event["stage"], "reviewer"; got != want {
		t.Fatalf("preflight failed stage = %v, want %q", got, want)
	}
	if !strings.Contains(fmt.Sprint(event["error"]), `provider CLI "claude" is not available on PATH`) {
		t.Fatalf("preflight failed error = %v, want missing CLI", event["error"])
	}
}

func TestRunSinglePassReviewerFailureDoesNotCancelOtherReviewers(t *testing.T) {
	env := testEnv(t)
	setMockPath(t)
	spawner := &partialFailureSpawner{
		failed: make(chan struct{}),
		err:    errors.New("claude parse failed"),
	}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
			{ID: "claude#1", Provider: "claude", Model: "stub"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v, want nil", err)
	}

	gate := readGate(t, env)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want %q", gate.Status, state.StatusResolved)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictPass {
		t.Fatalf("gate verdict = %v, want %q", gate.Verdict, state.VerdictPass)
	}

	events := readEventLog(t, env)
	assertEventCount(t, events, telemetry.EventReviewerFailed, 1)
	assertEventCount(t, events, telemetry.EventReviewerCompleted, 1)
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	passed := readJSONFile(t, filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", "codex#1", "output.json"))
	if _, ok := passed["verdict"]; ok {
		t.Fatalf("codex output verdict = %v, want omitted", passed["verdict"])
	}
}

func TestAggregateRoundOutputsTreatsReviewerFailuresAsAbstentions(t *testing.T) {
	for _, tc := range []struct {
		name      string
		consensus aggregate.Mode
		outputs   []roundReviewerResult
		want      string
	}{
		{
			name:      "all mode pass plus failure passes",
			consensus: aggregate.ModeAll,
			outputs:   []roundReviewerResult{roundOutput("PASS"), failedRoundOutput()},
			want:      aggregate.VerdictPass,
		},
		{
			name:      "any mode fail plus failure fails",
			consensus: aggregate.ModeAny,
			outputs:   []roundReviewerResult{roundOutput("FAIL"), failedRoundOutput()},
			want:      aggregate.VerdictFail,
		},
		{
			name:      "majority mode counts only successful reviewer votes",
			consensus: aggregate.ModeMajority,
			outputs: []roundReviewerResult{
				roundOutput("FAIL"),
				roundOutput("FAIL"),
				roundOutput("PASS"),
				failedRoundOutput(),
				failedRoundOutput(),
			},
			want: aggregate.VerdictFail,
		},
		{
			name:      "majority mode pass fail tie fails with reviewer failure abstention",
			consensus: aggregate.ModeMajority,
			outputs: []roundReviewerResult{
				roundOutput("PASS"),
				roundOutput("FAIL"),
				failedRoundOutput(),
			},
			want: aggregate.VerdictFail,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := aggregateRoundOutputs(tc.outputs, tc.consensus, aggregate.DefaultFailurePriority)
			if err != nil {
				t.Fatalf("aggregateRoundOutputs() error = %v", err)
			}
			if got.Verdict != tc.want {
				t.Fatalf("verdict = %q, want %q", got.Verdict, tc.want)
			}
		})
	}
}

func TestAggregateRoundOutputsRemapsBlockerIndexesAfterFailureFiltering(t *testing.T) {
	severity := "blocking"
	got, err := aggregateRoundOutputs([]roundReviewerResult{
		failedRoundOutput(),
		{
			Output: reviewer.RawReviewerOutput{Findings: []reviewer.RawFinding{{
				Title:    "blocks release",
				Body:     "blocks release",
				Severity: &severity,
			}}},
			Row: telemetry.ReviewerRow{Verdict: aggregate.VerdictFail},
		},
	}, aggregate.ModeMajority, aggregate.DefaultFailurePriority)
	if err != nil {
		t.Fatalf("aggregateRoundOutputs() error = %v", err)
	}
	if got.Verdict != aggregate.VerdictFail {
		t.Fatalf("verdict = %q, want %q", got.Verdict, aggregate.VerdictFail)
	}
	if len(got.Blockers) != 1 || got.Blockers[0].ReviewerIndex != 1 {
		t.Fatalf("blockers = %#v, want blocker index remapped to original reviewer index 1", got.Blockers)
	}
}

func TestConsensusPctExcludesReviewerFailures(t *testing.T) {
	got := consensusPct([]roundReviewerResult{
		roundOutput("PASS"),
		roundOutput("PASS"),
		failedRoundOutput(),
	}, aggregate.VerdictPass)
	if got != 1 {
		t.Fatalf("consensusPct() = %v, want 1", got)
	}
}

func roundOutput(verdict string) roundReviewerResult {
	findings := findingsForVerdict(verdict)
	gateVerdict := aggregate.VerdictForFindings(findings, aggregate.DefaultFailurePriority)
	return roundReviewerResult{
		Output: reviewer.RawReviewerOutput{Findings: findings},
		Row:    telemetry.ReviewerRow{Verdict: gateVerdict},
	}
}

func findingsForVerdict(verdict string) []reviewer.RawFinding {
	switch verdict {
	case "FAIL", "fail":
		priority := 1
		return []reviewer.RawFinding{{Title: "fail", Body: "fail", Priority: &priority}}
	case "NEEDS_WORK", "NEEDS WORK", "needs_work":
		priority := 2
		return []reviewer.RawFinding{{Title: "needs work", Body: "needs work", Priority: &priority}}
	default:
		return []reviewer.RawFinding{}
	}
}

func failedRoundOutput() roundReviewerResult {
	output := roundOutput("NEEDS_WORK")
	output.Row.Verdict = aggregate.VerdictRequiresDecision
	output.Failed = true
	return output
}

func TestRunSinglePassPassesSlotStrategyAsSystemPrompt(t *testing.T) {
	env := testEnv(t)
	env.Root = promptRoot(t)
	setMockPath(t)
	spawner := systemPromptSpawner{want: "Strategy: falsification-first."}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub", Strategy: "falsification-first"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}
}

func TestRunSinglePassIncludesReviewerTemplateForDefaultSlot(t *testing.T) {
	env := testEnv(t)
	env.Root = promptRoot(t)
	setMockPath(t)
	spawner := promptContentSpawner{
		wantUser:   "reviewer prompt\n\nreview this",
		wantSystem: "",
	}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}
}

func TestRunSinglePassIncludesReviewerTemplateWithStrategy(t *testing.T) {
	env := testEnv(t)
	env.Root = promptRoot(t)
	setMockPath(t)
	spawner := promptContentSpawner{
		wantSystem: "Strategy: falsification-first.",
		wantUser:   "reviewer prompt\n\nreview this",
	}

	err := RunSinglePass(context.Background(), env, Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "codex#1", Provider: "codex", Model: "stub", Strategy: "falsification-first"},
		},
	}, spawner)
	if err != nil {
		t.Fatalf("RunSinglePass() error = %v", err)
	}
}

type observingSpawner struct {
	t   *testing.T
	env *config.Env
}

func (spawner observingSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	gate := readGate(spawner.t, spawner.env)
	if gate.Status != state.StatusPending {
		return reviewer.Response{}, fmt.Errorf("gate status during spawn = %q, want %q", gate.Status, state.StatusPending)
	}
	return passResponse(request.ID)
}

type passSpawner struct{}

func (passSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	return passResponse(request.ID)
}

type needsWorkSpawner struct{}

func (needsWorkSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	confidence := 0.8
	round := 1
	priority := 3
	parsed := &reviewer.RawReviewerOutput{
		Findings: []reviewer.RawFinding{{
			Title:    "Clarify help example",
			Body:     "The help text is confusing.",
			Priority: &priority,
		}},
		Summary:           "non-blocking issue",
		OverallConfidence: &confidence,
		Round:             &round,
		PeerResponsesSeen: []string{},
	}
	output, err := json.Marshal(parsed)
	if err != nil {
		return reviewer.Response{}, err
	}
	return reviewer.Response{ID: request.ID, Output: output, Parsed: parsed}, nil
}

type dedupRecordingSpawner struct {
	dedupCalled   bool
	dedupPrompt   string
	dedupProvider string
	dedupModel    string
	dedupMode     string
	dedupFindings []reviewer.RawFinding
	dedupDelay    time.Duration
}

func (spawner *dedupRecordingSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	if request.ID == "cerberus-dedup#1" {
		if spawner.dedupDelay > 0 {
			time.Sleep(spawner.dedupDelay)
		}
		spawner.dedupCalled = true
		spawner.dedupPrompt = string(request.User)
		spawner.dedupProvider = request.Provider
		spawner.dedupModel = request.Model
		spawner.dedupMode = request.Mode
		if spawner.dedupFindings == nil {
			return passResponse(request.ID)
		}
		parsed := &reviewer.RawReviewerOutput{Findings: spawner.dedupFindings}
		output, err := json.Marshal(parsed)
		if err != nil {
			return reviewer.Response{}, err
		}
		return reviewer.Response{ID: request.ID, Output: output, Parsed: parsed}, nil
	}
	priority := 1
	confidence := 0.8
	parsed := &reviewer.RawReviewerOutput{
		Findings: []reviewer.RawFinding{{
			Title:      "duplicate bug",
			Body:       "same issue from another reviewer",
			Priority:   &priority,
			Confidence: &confidence,
		}},
	}
	output, err := json.Marshal(parsed)
	if err != nil {
		return reviewer.Response{}, err
	}
	return reviewer.Response{ID: request.ID, Output: output, Parsed: parsed}, nil
}

type errorSpawner struct {
	err error
}

func (spawner errorSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	return reviewer.Response{}, spawner.err
}

type systemPromptSpawner struct {
	want string
}

func (spawner systemPromptSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	if !strings.Contains(string(request.System), spawner.want) {
		return reviewer.Response{}, fmt.Errorf("system prompt = %q, want %q", request.System, spawner.want)
	}
	return passResponse(request.ID)
}

type promptContentSpawner struct {
	wantSystem string
	wantUser   string
}

func (spawner promptContentSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	if !strings.Contains(string(request.System), spawner.wantSystem) {
		return reviewer.Response{}, fmt.Errorf("system prompt = %q, want %q", request.System, spawner.wantSystem)
	}
	if got := string(request.User); got != spawner.wantUser {
		return reviewer.Response{}, fmt.Errorf("user prompt = %q, want %q", got, spawner.wantUser)
	}
	return passResponse(request.ID)
}

type modeSpawner struct {
	want string
}

func (spawner modeSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	if request.Mode != spawner.want {
		return reviewer.Response{}, fmt.Errorf("request mode = %q, want %q", request.Mode, spawner.want)
	}
	return passResponse(request.ID)
}

type usageSpawner struct{}

func (usageSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	response, err := passResponse(request.ID)
	if err != nil {
		return reviewer.Response{}, err
	}
	switch request.ID {
	case "codex#1":
		response.Tokens = reviewer.Tokens{Input: 10, Output: 5}
		response.CostUSD = 0.01
	case "claude#2":
		response.Tokens = reviewer.Tokens{Input: 20, Output: 7}
		response.CostUSD = 0.02
	}
	return response, nil
}

type partialFailureSpawner struct {
	failed chan struct{}
	err    error
}

type mixedVerdictFailureSpawner struct {
	verdicts map[string]string
	failures map[string]error
}

func (spawner mixedVerdictFailureSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	if request.ID == "cerberus-dedup#1" {
		for _, verdict := range spawner.verdicts {
			if verdict == "FAIL" || verdict == "fail" {
				return responseForVerdict(request.ID, "FAIL")
			}
		}
		return passResponse(request.ID)
	}
	if err := spawner.failures[request.ID]; err != nil {
		return reviewer.Response{}, err
	}
	return responseForVerdict(request.ID, spawner.verdicts[request.ID])
}

func (spawner *partialFailureSpawner) Spawn(ctx context.Context, request reviewer.Request) (reviewer.Response, error) {
	if request.ID == "claude#1" {
		close(spawner.failed)
		return reviewer.Response{}, spawner.err
	}
	<-spawner.failed
	select {
	case <-time.After(20 * time.Millisecond):
		return passResponse(request.ID)
	case <-ctx.Done():
		return reviewer.Response{}, ctx.Err()
	}
}

func responseForVerdict(id string, verdict string) (reviewer.Response, error) {
	if verdict == "" || verdict == "PASS" {
		return passResponse(id)
	}
	confidence := 0.9
	round := 1
	parsed := &reviewer.RawReviewerOutput{
		Findings:          findingsForVerdict(verdict),
		Summary:           strings.ToLower(verdict),
		OverallConfidence: &confidence,
		Round:             &round,
		PeerResponsesSeen: []string{},
	}
	output, err := json.Marshal(parsed)
	if err != nil {
		return reviewer.Response{}, err
	}
	return reviewer.Response{ID: id, Output: output, Parsed: parsed}, nil
}

func passResponse(id string) (reviewer.Response, error) {
	confidence := 0.9
	round := 1
	parsed := &reviewer.RawReviewerOutput{
		Findings:          []reviewer.RawFinding{},
		Summary:           "ok",
		OverallConfidence: &confidence,
		Strategy:          nil,
		Round:             &round,
		PeerResponsesSeen: []string{},
	}
	output, err := json.Marshal(parsed)
	if err != nil {
		return reviewer.Response{}, err
	}
	return reviewer.Response{ID: id, Output: output, Parsed: parsed}, nil
}

func promptRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "prompts", "strategies"), 0o755); err != nil {
		t.Fatalf("MkdirAll(strategies) error = %v", err)
	}
	if err := os.MkdirAll(filepath.Join(root, "prompts", "reviewers"), 0o755); err != nil {
		t.Fatalf("MkdirAll(reviewers) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "prompts", "strategies", "falsification-first.md"), []byte("Strategy: falsification-first."), 0o644); err != nil {
		t.Fatalf("WriteFile(strategy) error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "prompts", "reviewers", "code.md"), []byte("reviewer prompt"), 0o644); err != nil {
		t.Fatalf("WriteFile(reviewer prompt) error = %v", err)
	}
	return root
}

func testEnv(t *testing.T) *config.Env {
	t.Helper()
	return &config.Env{
		Host:       "generic",
		Root:       repoRoot(t),
		StateRoot:  t.TempDir(),
		ProjectKey: "project",
		RunKey:     "run",
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	return root
}

func testParams() Params {
	return Params{
		Prompt: []byte("review this"),
		Reviewers: []ReviewerSlot{
			{ID: "claude#1", Provider: "claude", Model: "stub"},
			{ID: "codex#1", Provider: "codex", Model: "stub"},
			{ID: "gemini#1", Provider: "gemini", Model: "stub"},
		},
	}
}

func readGate(t *testing.T, env *config.Env) *state.GateState {
	t.Helper()
	gate, err := state.ReadGateState(gatePath(env))
	if err != nil {
		t.Fatalf("ReadGateState() error = %v", err)
	}
	return gate
}

func readRunTelemetry(t *testing.T, env *config.Env) map[string]any {
	t.Helper()
	path := filepath.Join(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey), "run-telemetry.json")
	return readJSONFile(t, path)
}

func readEventLog(t *testing.T, env *config.Env) []map[string]any {
	t.Helper()
	path := filepath.Join(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey), "event-log.jsonl")
	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("Open(%s) error = %v", path, err)
	}
	defer file.Close()

	var events []map[string]any
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		var event map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			t.Fatalf("Unmarshal event %q error = %v", scanner.Text(), err)
		}
		events = append(events, event)
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("Scan(%s) error = %v", path, err)
	}
	return events
}

func assertEventCount(t *testing.T, events []map[string]any, eventName string, want int) {
	t.Helper()
	got := 0
	for _, event := range events {
		if event["event"] == eventName {
			got++
		}
	}
	if got != want {
		t.Fatalf("event count for %s = %d, want %d; events = %#v", eventName, got, want, events)
	}
}

func findEvent(t *testing.T, events []map[string]any, eventName string) map[string]any {
	t.Helper()
	for _, event := range events {
		if event["event"] == eventName {
			return event
		}
	}
	t.Fatalf("missing event %s in %#v", eventName, events)
	return nil
}

func readJSONFile(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	var got map[string]any
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("Unmarshal(%s) error = %v", path, err)
	}
	return got
}

func gatePath(env *config.Env) string {
	return state.GateStatePath(state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey))
}

func setMockPath(t *testing.T) {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	binDir := t.TempDir()
	for _, provider := range []string{"claude", "codex", "gemini"} {
		binary := filepath.Join(binDir, provider)
		build := exec.Command("go", "build", "-o", binary, "./tests/mocks/"+provider)
		build.Dir = repoRoot
		if output, err := build.CombinedOutput(); err != nil {
			t.Fatalf("go build ./tests/mocks/%s failed: %v\n%s", provider, err, output)
		}
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func writeFakeProvider(t *testing.T, dir, name string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", path, err)
	}
}

func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stderr
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe() error = %v", err)
	}
	os.Stderr = write
	defer func() {
		os.Stderr = old
	}()

	fn()

	if err := write.Close(); err != nil {
		t.Fatalf("close stderr pipe: %v", err)
	}
	data, err := io.ReadAll(read)
	if err != nil {
		t.Fatalf("read stderr pipe: %v", err)
	}
	return string(data)
}

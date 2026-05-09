package orchestrator

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/charlieyou/cerberus/internal/aggregate"
	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/host"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/roster"
	"github.com/charlieyou/cerberus/internal/state"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

type ConsensusMode = aggregate.Mode

// Params contains the single-pass review inputs.
type Params struct {
	Prompt         []byte
	ArtifactType   string
	Reviewers      []ReviewerSlot
	RosterDefaults RosterDefaults
	Mode           string
	MaxRounds      int
	Consensus      ConsensusMode
	RosterID       string
}

// RosterDefaults carries panel-wide defaults from rosters.yaml.
type RosterDefaults struct {
	Mode      string
	MaxRounds int
}

// ReviewerSlot names one resolved reviewer slot.
type ReviewerSlot struct {
	ID            string
	Provider      string
	Model         string
	Strategy      string
	PersonaPath   string
	Mode          string
	InstanceIndex int
}

// StartedRun contains the persisted inputs needed to finish a started review.
type StartedRun struct {
	Env     config.Env
	RunRoot string
	Params  Params
}

// RunSinglePass executes one review round and resolves the gate from reviewer output.
func RunSinglePass(ctx context.Context, env *config.Env, params Params, spawner reviewer.Spawner) error {
	started, err := StartSinglePass(env, params)
	if err != nil {
		return err
	}
	return CompleteSinglePass(ctx, started, spawner)
}

// StartSinglePass creates the pending gate and records review-spawn telemetry.
func StartSinglePass(env *config.Env, params Params) (*StartedRun, error) {
	if env == nil {
		env = config.Resolve()
	}
	resolvedEnv, runRoot, err := resolveRun(env)
	if err != nil {
		return nil, err
	}
	slots, defaults, err := resolveSlots(params)
	if err != nil {
		_ = writePreflightFailureEvent(runRoot, resolvedEnv, "roster", err)
		return nil, err
	}
	if err := preflightExplicitSlots(slots, params.Reviewers != nil); err != nil {
		_ = writePreflightFailureEvent(runRoot, resolvedEnv, "reviewer", err)
		return nil, err
	}

	gatePath := state.GateStatePath(runRoot)
	if existing, err := state.ReadGateState(gatePath); err == nil && existing.Status == state.StatusPending {
		fmt.Fprintf(os.Stderr, "warning: %s is already pending at %s; starting another review may overwrite active state\n", state.GateStateFilename(), gatePath)
	}

	startedAt := time.Now().UTC()
	mode := params.Mode
	if mode == "" {
		mode = defaults.Mode
	}
	if mode == "" {
		mode = "smart"
	}
	maxRounds := params.MaxRounds
	if maxRounds <= 0 {
		maxRounds = defaults.MaxRounds
	}
	if maxRounds <= 0 {
		maxRounds = 1
	}
	rosterID := params.RosterID
	if rosterID == "" {
		rosterID = "default"
	}
	consensus := params.Consensus
	if consensus == "" {
		consensus = aggregate.ModeMajority
	}
	artifactType := params.ArtifactType
	if artifactType == "" {
		artifactType = "code"
	}

	gate := &state.GateState{
		RunKey:           resolvedEnv.RunKey,
		Host:             resolvedEnv.Host,
		ProjectKey:       resolvedEnv.ProjectKey,
		SessionID:        resolvedEnv.SessionID,
		TranscriptPath:   resolvedEnv.TranscriptPath,
		Status:           state.StatusPending,
		Verdict:          nil,
		CurrentIteration: 1,
		MaxRounds:        maxRounds,
		Debate:           false,
		RosterID:         rosterID,
		StartedAt:        startedAt,
	}
	if err := state.WriteGateState(gatePath, gate); err != nil {
		return nil, err
	}
	if err := telemetry.WriteEvent(runRoot, telemetry.Event{
		Event:     telemetry.EventRosterSelected,
		Timestamp: startedAt,
		Payload: map[string]any{
			"run_key":        resolvedEnv.RunKey,
			"host":           resolvedEnv.Host,
			"roster_id":      rosterID,
			"roster_name":    rosterID,
			"reviewer_count": len(slots),
			"providers":      providerBreakdown(slots),
			"debate":         false,
		},
	}); err != nil {
		state.MarkResolved(gate, state.VerdictRequiresDecision, time.Now().UTC(), fmt.Sprintf("roster selected telemetry failed: %v", err))
		_ = state.WriteGateState(gatePath, gate)
		return nil, err
	}
	if err := telemetry.WriteEvent(runRoot, telemetry.Event{
		Event:     telemetry.EventReviewSpawned,
		Timestamp: startedAt,
		Payload: map[string]any{
			"run_key":        resolvedEnv.RunKey,
			"reviewer_count": len(slots),
		},
	}); err != nil {
		state.MarkResolved(gate, state.VerdictRequiresDecision, time.Now().UTC(), fmt.Sprintf("single-pass spawn telemetry failed: %v", err))
		_ = state.WriteGateState(gatePath, gate)
		return nil, err
	}
	params.Reviewers = slots
	params.RosterDefaults = defaults
	params.Mode = mode
	params.MaxRounds = maxRounds
	params.Consensus = consensus
	params.RosterID = rosterID
	params.ArtifactType = artifactType
	return &StartedRun{Env: *resolvedEnv, RunRoot: runRoot, Params: params}, nil
}

// RecordPreflightFailure records a pre-run validation failure when the CLI
// rejects input before it can create a pending gate.
func RecordPreflightFailure(env *config.Env, stage string, cause error) error {
	if env == nil {
		env = config.Resolve()
	}
	resolvedEnv, runRoot, err := resolveRun(env)
	if err != nil {
		return err
	}
	return writePreflightFailureEvent(runRoot, resolvedEnv, stage, cause)
}

// CompleteSinglePass runs reviewers for a pending gate and resolves it.
func CompleteSinglePass(ctx context.Context, started *StartedRun, spawner reviewer.Spawner) error {
	if started == nil {
		return fmt.Errorf("started run is required")
	}
	if spawner == nil {
		spawner = reviewer.Runner{
			Root:      started.Env.Root,
			RunRoot:   started.RunRoot,
			Iteration: 1,
			Round:     1,
		}
	}

	roundStartedAt := time.Now().UTC()
	roundResults, result, err := runRound(ctx, started.Params.Reviewers, spawner, roundPrompts{
		User:         started.Params.Prompt,
		ArtifactType: started.Params.ArtifactType,
		RunRoot:      started.RunRoot,
		Root:         started.Env.Root,
		RuntimeMode:  started.Params.Mode,
		Consensus:    started.Params.Consensus,
	})
	if err != nil {
		return err
	}

	endedAt := time.Now().UTC()
	reviewerSummary, totalTokens, totalCostUSD := telemetryTotals(roundResults)
	if err := telemetry.WriteRoundTelemetry(started.RunRoot, 1, 1, &telemetry.RoundTelemetry{
		Round:         1,
		ReviewerCount: len(roundResults),
		ConsensusPct:  consensusPct(roundResults, result.Verdict),
		Abstentions:   0,
		KStarEstimate: nil,
		StartedAt:     roundStartedAt,
		EndedAt:       &endedAt,
	}); err != nil {
		return err
	}
	if err := telemetry.WriteEvent(started.RunRoot, telemetry.Event{
		Event:     telemetry.EventReviewRoundComplete,
		Timestamp: endedAt,
		Payload: map[string]any{
			"round":           1,
			"consensus_pct":   consensusPct(roundResults, result.Verdict),
			"abstentions":     0,
			"k_star_estimate": nil,
		},
	}); err != nil {
		return err
	}
	gatePath := state.GateStatePath(started.RunRoot)
	gate, err := state.ReadGateState(gatePath)
	if err != nil {
		return err
	}
	startedAt := gate.StartedAt
	if err := telemetry.WriteIterationTelemetry(started.RunRoot, 1, &telemetry.IterationTelemetry{
		Iteration:       1,
		Rounds:          1,
		Verdict:         result.Verdict,
		ReviewerSummary: reviewerSummary,
		StartedAt:       startedAt,
		EndedAt:         &endedAt,
	}); err != nil {
		return err
	}
	state.MarkResolved(gate, result.Verdict, endedAt)
	if err := state.WriteGateState(gatePath, gate); err != nil {
		return err
	}
	if err := telemetry.WriteEvent(started.RunRoot, telemetry.Event{
		Event:     telemetry.EventReviewResolved,
		Timestamp: endedAt,
		Payload: map[string]any{
			"run_key": started.Env.RunKey,
			"verdict": result.Verdict,
		},
	}); err != nil {
		return err
	}
	return telemetry.WriteRunTelemetry(started.RunRoot, &telemetry.RunTelemetry{
		RunKey:       started.Env.RunKey,
		Host:         started.Env.Host,
		Mode:         started.Params.Mode,
		RosterID:     started.Params.RosterID,
		Debate:       false,
		Iterations:   1,
		TotalRounds:  1,
		TotalTokens:  totalTokens,
		TotalCostUSD: totalCostUSD,
		FinalVerdict: result.Verdict,
		StartedAt:    startedAt,
		EndedAt:      &endedAt,
	})
}

// ResolveSinglePassFailure resolves a detached review gate when the runtime
// cannot produce a reviewer aggregate.
func ResolveSinglePassFailure(started *StartedRun, cause error) error {
	if started == nil {
		return fmt.Errorf("started run is required")
	}
	gatePath := state.GateStatePath(started.RunRoot)
	gate, err := state.ReadGateState(gatePath)
	if err != nil {
		return err
	}
	if gate.Status == state.StatusResolved {
		return nil
	}
	reason := "single-pass runtime failed"
	if cause != nil {
		reason = fmt.Sprintf("%s: %v", reason, cause)
	}
	state.MarkResolved(gate, state.VerdictRequiresDecision, time.Now().UTC(), reason)
	return state.WriteGateState(gatePath, gate)
}

func telemetryTotals(results []roundReviewerResult) ([]telemetry.ReviewerSummary, telemetry.Tokens, float64) {
	summary := make([]telemetry.ReviewerSummary, len(results))
	var totalTokens telemetry.Tokens
	var totalCostUSD float64
	for i, result := range results {
		row := result.Row
		summary[i] = telemetry.ReviewerSummary{
			ReviewerID: row.ReviewerID,
			Verdict:    row.Verdict,
			Tokens:     row.Tokens,
			CostUSD:    row.CostUSD,
		}
		totalTokens.Input += row.Tokens.Input
		totalTokens.Output += row.Tokens.Output
		totalCostUSD += row.CostUSD
	}
	return summary, totalTokens, totalCostUSD
}

func consensusPct(results []roundReviewerResult, verdict string) float64 {
	if len(results) == 0 {
		return 0
	}
	matching := 0
	for _, result := range results {
		if result.Row.Verdict == verdict {
			matching++
		}
	}
	return float64(matching) / float64(len(results))
}

func resolveRun(env *config.Env) (*config.Env, string, error) {
	resolved := *env
	if resolved.Host == "" {
		resolved.Host = "generic"
	}
	if resolved.RunKey == "" {
		resolved.RunKey = resolved.SessionID
	}

	adapter, err := host.NewFromEnv(&resolved)
	if err != nil {
		return nil, "", err
	}
	if resolved.ProjectKey == "" {
		projectKey, err := adapter.ProjectKey(&resolved)
		if err != nil {
			return nil, "", err
		}
		resolved.ProjectKey = projectKey
	}
	if resolved.StateRoot == "" {
		stateRoot, err := adapter.StateRoot(&resolved)
		if err != nil {
			return nil, "", err
		}
		resolved.StateRoot = stateRoot
	}
	if resolved.RunKey == "" {
		if err := applySessionCache(&resolved); err != nil {
			return nil, "", err
		}
	}
	if resolved.RunKey == "" {
		return nil, "", fmt.Errorf("CERBERUS_RUN_KEY or CERBERUS_SESSION_ID is required")
	}
	runRoot := state.RunDir(resolved.StateRoot, resolved.ProjectKey, resolved.RunKey)
	if err := state.EnsureRunDir(runRoot); err != nil {
		return nil, "", err
	}
	return &resolved, runRoot, nil
}

func applySessionCache(env *config.Env) error {
	cache, err := state.ReadSessionCache(state.SessionCachePath(env.StateRoot, env.ProjectKey))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	env.RunKey = cache.RunKey
	env.SessionID = cache.SessionID
	env.TranscriptPath = cache.TranscriptPath
	return nil
}

func resolveSlots(params Params) ([]ReviewerSlot, RosterDefaults, error) {
	if len(params.Reviewers) > 0 {
		return params.Reviewers, params.RosterDefaults, nil
	}

	file, err := roster.LoadRosters("")
	if err != nil {
		return nil, RosterDefaults{}, err
	}
	resolved, err := roster.Resolve(file, "", nil, "")
	if err != nil {
		return nil, RosterDefaults{}, err
	}
	defaults := RosterDefaults{}
	if file != nil {
		defaults.Mode = file.Defaults.Mode
		if file.Defaults.MaxRounds != nil {
			defaults.MaxRounds = *file.Defaults.MaxRounds
		}
	}
	return reviewerSlotsFromRoster(resolved), defaults, nil
}

func reviewerSlotsFromRoster(slots []roster.RosterSlot) []ReviewerSlot {
	reviewers := make([]ReviewerSlot, len(slots))
	for i, slot := range slots {
		reviewers[i] = ReviewerSlot{
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

func providerBreakdown(slots []ReviewerSlot) map[string]int {
	providers := make(map[string]int)
	for _, slot := range slots {
		providers[slot.Provider]++
	}
	return providers
}

func writePreflightFailureEvent(runRoot string, env *config.Env, stage string, cause error) error {
	if runRoot == "" {
		return nil
	}
	payload := map[string]any{
		"stage": stage,
	}
	if env != nil {
		payload["run_key"] = env.RunKey
		payload["host"] = env.Host
		payload["project_key"] = env.ProjectKey
	}
	if cause != nil {
		payload["error"] = cause.Error()
	}
	var reasoned interface {
		TelemetryReason() string
	}
	if cause != nil && errors.As(cause, &reasoned) && reasoned.TelemetryReason() != "" {
		payload["reason"] = reasoned.TelemetryReason()
	}
	return telemetry.WriteEvent(runRoot, telemetry.Event{
		Event:     telemetry.EventPreflightFailed,
		Timestamp: time.Now().UTC(),
		Payload:   payload,
	})
}

func preflightExplicitSlots(slots []ReviewerSlot, explicit bool) error {
	if !explicit {
		return nil
	}
	for i, slot := range slots {
		slotIndex := i + 1
		if slot.ID == "" {
			return fmt.Errorf("reviewer preflight slot %d: id is required", slotIndex)
		}
		if slot.Provider == "" {
			return fmt.Errorf("reviewer preflight slot %d: provider is required", slotIndex)
		}
		if slot.Model == "" {
			return fmt.Errorf("reviewer preflight slot %d: model is required", slotIndex)
		}
		switch slot.Provider {
		case "claude", "codex", "gemini":
		default:
			return fmt.Errorf("reviewer preflight slot %d: unsupported provider %q", slotIndex, slot.Provider)
		}
		if _, err := exec.LookPath(slot.Provider); err != nil {
			return fmt.Errorf("reviewer preflight slot %d: provider CLI %q is not available on PATH", slotIndex, slot.Provider)
		}
	}
	return nil
}

package orchestrator

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/charlieyou/cerberus/internal/aggregate"
	"github.com/charlieyou/cerberus/internal/anonymize"
	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/state"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

type Verdict = aggregate.Result

// Orchestrator owns multi-round review execution.
type Orchestrator struct {
	Env                    *config.Env
	Spawner                reviewer.Spawner
	Consensus              aggregate.Mode
	Mode                   string
	RosterID               string
	AnonymizePeerBroadcast func([]reviewer.RawReviewerOutput, []string) ([]anonymize.PeerRecord, error)
}

// RunDebate executes a multi-round debate review on the same orchestrator path
// as single-pass review, inserting an anonymized peer broadcast between rounds.
func (o Orchestrator) RunDebate(ctx context.Context, slots []ReviewerSlot, prompt []byte, maxRounds int) (Verdict, error) {
	started, err := o.StartDebate(Params{
		Prompt:    prompt,
		Reviewers: slots,
		Mode:      o.Mode,
		MaxRounds: maxRounds,
		Consensus: o.Consensus,
		RosterID:  o.RosterID,
	})
	if err != nil {
		return Verdict{}, err
	}
	return o.CompleteDebate(ctx, started)
}

// StartDebate creates the pending gate for a detached debate runtime.
func (o Orchestrator) StartDebate(params Params) (*StartedRun, error) {
	if params.Mode == "" {
		params.Mode = params.RosterDefaults.Mode
	}
	if params.Mode == "" {
		params.Mode = "smart"
	}
	if params.MaxRounds <= 0 {
		params.MaxRounds = params.RosterDefaults.MaxRounds
	}
	if params.MaxRounds <= 0 {
		params.MaxRounds = 3
	}
	if params.Consensus == "" {
		params.Consensus = aggregate.ModeMajority
	}
	if params.RosterID == "" {
		params.RosterID = "default"
	}
	return o.startDebate(params)
}

func (o Orchestrator) startDebate(params Params) (*StartedRun, error) {
	slots := params.Reviewers
	maxRounds := params.MaxRounds
	if maxRounds <= 0 {
		maxRounds = 3
	}
	if len(slots) < 2 {
		return nil, fmt.Errorf("debate requires at least two reviewers")
	}

	env := o.Env
	if env == nil {
		env = config.Resolve()
	}
	resolvedEnv, runRoot, err := resolveRun(env)
	if err != nil {
		return nil, err
	}
	if err := preflightExplicitSlots(slots, true); err != nil {
		_ = writePreflightFailureEvent(runRoot, resolvedEnv, "reviewer", err)
		return nil, err
	}

	startedAt := time.Now().UTC()
	consensus := params.Consensus
	if o.Consensus != "" {
		consensus = o.Consensus
	}
	if consensus == "" {
		consensus = aggregate.ModeMajority
	}
	mode := params.Mode
	if o.Mode != "" {
		mode = o.Mode
	}
	if mode == "" {
		mode = "smart"
	}
	rosterID := o.RosterID
	if rosterID == "" {
		rosterID = params.RosterID
	}
	if rosterID == "" {
		rosterID = "default"
	}

	gate := &state.GateState{
		RunKey:           resolvedEnv.RunKey,
		Host:             resolvedEnv.Host,
		ProjectKey:       resolvedEnv.ProjectKey,
		SessionID:        resolvedEnv.SessionID,
		TranscriptPath:   resolvedEnv.TranscriptPath,
		Status:           state.StatusPending,
		CurrentIteration: 1,
		MaxRounds:        maxRounds,
		Debate:           true,
		RosterID:         rosterID,
		StartedAt:        startedAt,
	}
	gatePath := state.GateStatePath(runRoot)
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
			"debate":         true,
		},
	}); err != nil {
		state.MarkResolved(gate, state.VerdictRequiresDecision, time.Now().UTC(), fmt.Sprintf("roster selected telemetry failed: %v", err))
		_ = state.WriteGateState(gatePath, gate)
		return nil, err
	}
	params.Reviewers = slots
	params.Mode = mode
	params.MaxRounds = maxRounds
	params.Consensus = consensus
	params.RosterID = rosterID
	return &StartedRun{Env: *resolvedEnv, RunRoot: runRoot, Params: params}, nil
}

// CompleteDebate runs reviewers for a pending debate gate and resolves it.
func (o Orchestrator) CompleteDebate(ctx context.Context, started *StartedRun) (Verdict, error) {
	if started == nil {
		return Verdict{}, fmt.Errorf("started run is required")
	}
	resolvedEnv := &started.Env
	runRoot := started.RunRoot
	slots := started.Params.Reviewers
	prompt := started.Params.Prompt
	maxRounds := started.Params.MaxRounds
	consensus := started.Params.Consensus
	if consensus == "" {
		consensus = aggregate.ModeMajority
	}
	mode := started.Params.Mode
	if mode == "" {
		mode = "smart"
	}
	rosterID := started.Params.RosterID
	if rosterID == "" {
		rosterID = "default"
	}

	spawner := o.Spawner
	if spawner == nil {
		spawner = reviewer.Runner{Root: resolvedEnv.Root, RunRoot: runRoot, Iteration: 1}
	}
	anonymizeBroadcast := o.AnonymizePeerBroadcast
	if anonymizeBroadcast == nil {
		anonymizeBroadcast = anonymize.AnonymizePeerBroadcast
	}
	rosterModelNames := modelNames(slots)

	var final Verdict
	var previous []reviewer.RawReviewerOutput
	var finalRoundResults []roundReviewerResult
	var totalTokens telemetry.Tokens
	var totalCostUSD float64
	roundsCompleted := 0
	roundPrompt := prompt

	for round := 1; round <= maxRounds; round++ {
		if round > 1 {
			records, err := anonymizeBroadcast(previous, rosterModelNames)
			if err != nil {
				return Verdict{}, err
			}
			broadcast, err := writePeerBroadcast(runRoot, 1, round, records)
			if err != nil {
				return Verdict{}, err
			}
			roundPrompt = promptWithPeerBroadcast(prompt, broadcast)
		}

		roundStartedAt := time.Now().UTC()
		roundResults, err := runRound(ctx, slots, spawner, roundPrompts{
			User:        roundPrompt,
			RunRoot:     runRoot,
			Root:        resolvedEnv.Root,
			RuntimeMode: mode,
			Iteration:   1,
			Round:       round,
		})
		if err != nil {
			return Verdict{}, err
		}
		outputs := make([]reviewer.RawReviewerOutput, len(roundResults))
		for i, result := range roundResults {
			outputs[i] = result.Output
			outputs[i].InstanceID = slots[i].ID
			totalTokens.Input += result.Row.Tokens.Input
			totalTokens.Output += result.Row.Tokens.Output
			totalCostUSD += result.Row.CostUSD
		}
		result, err := aggregate.Compute(outputs, consensus)
		if err != nil {
			return Verdict{}, err
		}
		final = result
		previous = outputs
		finalRoundResults = roundResults
		roundsCompleted = round

		endedAt := time.Now().UTC()
		if err := telemetry.WriteRoundTelemetry(runRoot, 1, round, &telemetry.RoundTelemetry{
			Round:         round,
			ReviewerCount: len(roundResults),
			ConsensusPct:  consensusPct(roundResults, result.Verdict),
			Abstentions:   0,
			KStarEstimate: nil,
			StartedAt:     roundStartedAt,
			EndedAt:       &endedAt,
		}); err != nil {
			return Verdict{}, err
		}
		if result.Verdict == aggregate.VerdictPass || result.Verdict == aggregate.VerdictFail {
			break
		}
	}

	endedAt := time.Now().UTC()
	reviewerSummary, _, _ := telemetryTotals(finalRoundResults)
	gatePath := state.GateStatePath(runRoot)
	gate, err := state.ReadGateState(gatePath)
	if err != nil {
		return Verdict{}, err
	}
	startedAt := gate.StartedAt
	if err := telemetry.WriteIterationTelemetry(runRoot, 1, &telemetry.IterationTelemetry{
		Iteration:       1,
		Rounds:          roundsCompleted,
		Verdict:         final.Verdict,
		ReviewerSummary: reviewerSummary,
		StartedAt:       startedAt,
		EndedAt:         &endedAt,
	}); err != nil {
		return Verdict{}, err
	}
	state.MarkResolved(gate, final.Verdict, endedAt)
	if err := state.WriteGateState(gatePath, gate); err != nil {
		return Verdict{}, err
	}
	if err := telemetry.WriteRunTelemetry(runRoot, &telemetry.RunTelemetry{
		RunKey:       resolvedEnv.RunKey,
		Host:         resolvedEnv.Host,
		Mode:         mode,
		RosterID:     rosterID,
		Debate:       true,
		Iterations:   1,
		TotalRounds:  roundsCompleted,
		TotalTokens:  totalTokens,
		TotalCostUSD: totalCostUSD,
		FinalVerdict: final.Verdict,
		StartedAt:    startedAt,
		EndedAt:      &endedAt,
	}); err != nil {
		return Verdict{}, err
	}
	return final, nil
}

// ResolveDebateFailure resolves a detached debate gate when the runtime cannot
// produce a reviewer aggregate.
func ResolveDebateFailure(started *StartedRun, cause error) error {
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
	reason := "debate runtime failed"
	if cause != nil {
		reason = fmt.Sprintf("%s: %v", reason, cause)
	}
	state.MarkResolved(gate, state.VerdictRequiresDecision, time.Now().UTC(), reason)
	return state.WriteGateState(gatePath, gate)
}

func writePeerBroadcast(runRoot string, iteration, round int, records []anonymize.PeerRecord) ([]byte, error) {
	data, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal peer broadcast: %w", err)
	}
	data = append(data, '\n')
	path := filepath.Join(state.RoundDir(runRoot, iteration, round), "peer-broadcast.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("create peer broadcast directory: %w", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return nil, fmt.Errorf("write peer broadcast: %w", err)
	}
	return data, nil
}

func modelNames(slots []ReviewerSlot) []string {
	models := make([]string, 0, len(slots))
	for _, slot := range slots {
		if slot.Model != "" {
			models = append(models, slot.Model)
		}
	}
	return models
}

func promptWithPeerBroadcast(prompt, broadcast []byte) []byte {
	return appendPrompt(prompt, append([]byte("{{PEER_BROADCAST}}\n"), append(broadcast, []byte("{{/PEER_BROADCAST}}")...)...))
}

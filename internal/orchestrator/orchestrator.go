package orchestrator

import (
	"context"
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

// Params contains the single-pass review inputs.
type Params struct {
	Prompt    []byte
	Reviewers []ReviewerSlot
	Mode      string
	MaxRounds int
	Consensus aggregate.Mode
	RosterID  string
}

// ReviewerSlot names one resolved reviewer slot.
type ReviewerSlot struct {
	ID       string
	Provider string
	Model    string
}

// RunSinglePass executes one review round and resolves the gate from reviewer output.
func RunSinglePass(ctx context.Context, env *config.Env, params Params, spawner reviewer.Spawner) error {
	if env == nil {
		env = config.Resolve()
	}
	slots, err := resolveSlots(params)
	if err != nil {
		return err
	}
	if err := preflightExplicitSlots(slots, params.Reviewers != nil); err != nil {
		return err
	}

	resolvedEnv, runRoot, err := resolveRun(env)
	if err != nil {
		return err
	}
	if spawner == nil {
		spawner = reviewer.Runner{
			Root:      resolvedEnv.Root,
			RunRoot:   runRoot,
			Iteration: 1,
			Round:     1,
		}
	}

	gatePath := state.GateStatePath(runRoot)
	if existing, err := state.ReadGateState(gatePath); err == nil && existing.Status == state.StatusPending {
		fmt.Fprintf(os.Stderr, "warning: gate-state.json is already pending at %s; starting another review may overwrite active state\n", gatePath)
	}

	startedAt := time.Now().UTC()
	mode := params.Mode
	if mode == "" {
		mode = "smart"
	}
	maxRounds := params.MaxRounds
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
		return err
	}
	if err := telemetry.WriteEvent(runRoot, telemetry.Event{
		Event:     telemetry.EventReviewSpawned,
		Timestamp: startedAt,
		Payload: map[string]any{
			"run_key":        resolvedEnv.RunKey,
			"reviewer_count": len(slots),
		},
	}); err != nil {
		return err
	}

	outputs, err := runRound(ctx, slots, spawner, roundPrompts{
		User:    params.Prompt,
		RunRoot: runRoot,
		Root:    resolvedEnv.Root,
	})
	if err != nil {
		return err
	}
	result, err := aggregate.Compute(outputs, consensus)
	if err != nil {
		return err
	}

	endedAt := time.Now().UTC()
	state.MarkResolved(gate, result.Verdict, endedAt)
	if err := state.WriteGateState(gatePath, gate); err != nil {
		return err
	}
	if err := telemetry.WriteEvent(runRoot, telemetry.Event{
		Event:     telemetry.EventReviewResolved,
		Timestamp: endedAt,
		Payload: map[string]any{
			"run_key": resolvedEnv.RunKey,
			"verdict": result.Verdict,
		},
	}); err != nil {
		return err
	}
	return telemetry.WriteRunTelemetry(runRoot, &telemetry.RunTelemetry{
		RunKey:       resolvedEnv.RunKey,
		Host:         resolvedEnv.Host,
		Mode:         mode,
		RosterID:     rosterID,
		Debate:       false,
		Iterations:   1,
		TotalRounds:  1,
		FinalVerdict: result.Verdict,
		StartedAt:    startedAt,
		EndedAt:      &endedAt,
	})
}

func resolveRun(env *config.Env) (*config.Env, string, error) {
	resolved := *env
	if resolved.Host == "" {
		resolved.Host = "generic"
	}
	if resolved.RunKey == "" {
		resolved.RunKey = resolved.SessionID
	}
	if resolved.RunKey == "" {
		return nil, "", fmt.Errorf("CERBERUS_RUN_KEY or CERBERUS_SESSION_ID is required")
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
	runRoot := state.RunDir(resolved.StateRoot, resolved.ProjectKey, resolved.RunKey)
	if err := state.EnsureRunDir(runRoot); err != nil {
		return nil, "", err
	}
	return &resolved, runRoot, nil
}

func resolveSlots(params Params) ([]ReviewerSlot, error) {
	if len(params.Reviewers) > 0 {
		return params.Reviewers, nil
	}

	file, err := roster.LoadRosters("")
	if err != nil {
		return nil, err
	}
	resolved, err := roster.Resolve(file, "", nil, "")
	if err != nil {
		return nil, err
	}
	slots := make([]ReviewerSlot, len(resolved))
	for i, slot := range resolved {
		slots[i] = ReviewerSlot{
			ID:       slot.InstanceID,
			Provider: slot.Provider,
			Model:    slot.Model,
		}
	}
	return slots, nil
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

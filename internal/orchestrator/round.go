package orchestrator

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/charlieyou/cerberus/internal/aggregate"
	"github.com/charlieyou/cerberus/internal/prompts"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/roster"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

type roundPrompts struct {
	System      []byte
	User        []byte
	Root        string
	RunRoot     string
	RuntimeMode string
}

type roundReviewerResult struct {
	Output reviewer.RawReviewerOutput
	Row    telemetry.ReviewerRow
}

func runRound(ctx context.Context, slots []ReviewerSlot, spawner reviewer.Spawner, prompts roundPrompts) ([]roundReviewerResult, error) {
	if len(slots) == 0 {
		return nil, fmt.Errorf("review round requires at least one reviewer")
	}
	if spawner == nil {
		return nil, fmt.Errorf("reviewer spawner is nil")
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	outputs := make([]roundReviewerResult, len(slots))
	errs := make(chan roundError, len(slots))
	var wg sync.WaitGroup

	for i, slot := range slots {
		i, slot := i, slot
		wg.Add(1)
		go func() {
			defer wg.Done()

			system, user, err := promptsForSlot(slot, prompts)
			if err != nil {
				errs <- roundError{err: err}
				cancel()
				return
			}
			startedAt := time.Now().UTC()
			if err := writeReviewerEvent(prompts.RunRoot, telemetry.EventReviewerStarted, slot, i, startedAt, nil); err != nil {
				errs <- roundError{err: err}
				cancel()
				return
			}
			response, err := spawner.Spawn(ctx, reviewer.Request{
				ID:        slot.ID,
				Provider:  slot.Provider,
				Model:     slot.Model,
				Mode:      firstNonEmpty(slot.Mode, prompts.RuntimeMode),
				System:    system,
				User:      user,
				Root:      prompts.Root,
				RunRoot:   prompts.RunRoot,
				Iteration: 1,
				Round:     1,
			})
			if err != nil {
				errs <- roundError{err: withReviewerFailureEvent(prompts.RunRoot, slot, i, err)}
				cancel()
				return
			}
			endedAt := time.Now().UTC()
			parsed := response.Parsed
			if parsed == nil {
				parsed, err = reviewer.Parse(response.Output)
				if err != nil {
					errs <- roundError{err: withReviewerFailureEvent(prompts.RunRoot, slot, i, err)}
					cancel()
					return
				}
			}
			row, err := reviewerTelemetryRow(slot, i, prompts.RuntimeMode, response, parsed, startedAt, endedAt)
			if err != nil {
				errs <- roundError{err: withReviewerFailureEvent(prompts.RunRoot, slot, i, err)}
				cancel()
				return
			}
			if prompts.RunRoot != "" {
				if err := telemetry.WriteReviewerRow(prompts.RunRoot, 1, 1, &row); err != nil {
					errs <- roundError{err: withReviewerFailureEvent(prompts.RunRoot, slot, i, err)}
					cancel()
					return
				}
			}
			if err := writeReviewerEvent(prompts.RunRoot, telemetry.EventReviewerCompleted, slot, i, endedAt, map[string]any{
				"verdict": row.Verdict,
			}); err != nil {
				errs <- roundError{err: err}
				cancel()
				return
			}
			outputs[i] = roundReviewerResult{Output: *parsed, Row: row}
		}()
	}

	wg.Wait()
	close(errs)
	var canceled error
	for result := range errs {
		if result.err == nil {
			continue
		}
		if errors.Is(result.err, context.Canceled) {
			if canceled == nil {
				canceled = result.err
			}
			continue
		}
		return nil, result.err
	}
	if canceled != nil {
		return nil, canceled
	}
	return outputs, nil
}

func withReviewerFailureEvent(runRoot string, slot ReviewerSlot, slotIndex int, original error) error {
	if eventErr := writeReviewerEvent(runRoot, telemetry.EventReviewerFailed, slot, slotIndex, time.Now().UTC(), map[string]any{
		"error": original.Error(),
	}); eventErr != nil {
		return fmt.Errorf("%w; record reviewer failure event: %v", original, eventErr)
	}
	return original
}

func writeReviewerEvent(runRoot string, eventName string, slot ReviewerSlot, slotIndex int, at time.Time, extra map[string]any) error {
	if runRoot == "" {
		return nil
	}
	payload := map[string]any{
		"reviewer_id":    slot.ID,
		"instance_index": reviewerInstanceIndex(slot, slotIndex),
		"provider":       slot.Provider,
		"model":          slot.Model,
		"round":          1,
	}
	for key, value := range extra {
		payload[key] = value
	}
	return telemetry.WriteEvent(runRoot, telemetry.Event{
		Event:     eventName,
		Timestamp: at,
		Payload:   payload,
	})
}

func reviewerTelemetryRow(slot ReviewerSlot, slotIndex int, runtimeMode string, response reviewer.Response, output *reviewer.RawReviewerOutput, startedAt, endedAt time.Time) (telemetry.ReviewerRow, error) {
	verdict, err := aggregate.NormalizeVerdict(output.Verdict)
	if err != nil {
		return telemetry.ReviewerRow{}, err
	}
	instanceIndex := reviewerInstanceIndex(slot, slotIndex)
	reviewerID := firstNonEmpty(response.ID, slot.ID)
	confidence := 0.5
	if output.OverallConfidence != nil {
		confidence = *output.OverallConfidence
	}
	round := 1
	if output.Round != nil && *output.Round > 0 {
		round = *output.Round
	}

	return telemetry.ReviewerRow{
		ReviewerID:        reviewerID,
		InstanceIndex:     instanceIndex,
		Provider:          slot.Provider,
		Model:             slot.Model,
		Strategy:          slot.Strategy,
		PersonaName:       personaName(slot.PersonaPath),
		Mode:              firstNonEmpty(slot.Mode, runtimeMode),
		Tokens:            telemetry.Tokens{Input: response.Tokens.Input, Output: response.Tokens.Output},
		CostUSD:           response.CostUSD,
		PeerID:            fmt.Sprintf("peer_%d", instanceIndex),
		Verdict:           verdict,
		OverallConfidence: confidence,
		Round:             round,
		TimeToFinishMS:    endedAt.Sub(startedAt).Milliseconds(),
		StartedAt:         startedAt,
		EndedAt:           &endedAt,
	}, nil
}

func reviewerInstanceIndex(slot ReviewerSlot, slotIndex int) int {
	if slot.InstanceIndex > 0 {
		return slot.InstanceIndex
	}
	return slotIndex + 1
}

func personaName(path string) *string {
	if path == "" {
		return nil
	}
	name := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	if name == "" || name == "." {
		return nil
	}
	return &name
}

func promptsForSlot(slot ReviewerSlot, round roundPrompts) ([]byte, []byte, error) {
	root := round.Root
	if root == "" {
		root = "."
	}
	system, user, err := prompts.ComposeFromRoot(root, roster.RosterSlot{
		Provider:    slot.Provider,
		Model:       slot.Model,
		Strategy:    slot.Strategy,
		PersonaPath: slot.PersonaPath,
		Mode:        slot.Mode,
	}, "code")
	if err != nil {
		return nil, nil, err
	}
	user = appendPrompt(user, round.User)
	if len(round.System) == 0 {
		return system, user, nil
	}
	if len(system) == 0 {
		return round.System, user, nil
	}
	return bytes.Join([][]byte{round.System, system}, []byte("\n\n")), user, nil
}

func appendPrompt(base, extra []byte) []byte {
	if len(base) == 0 {
		return extra
	}
	if len(extra) == 0 {
		return base
	}
	return bytes.Join([][]byte{base, extra}, []byte("\n\n"))
}

type roundError struct {
	err error
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

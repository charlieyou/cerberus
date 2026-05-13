package orchestrator

import (
	"bytes"
	"context"
	"encoding/json"
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
	"github.com/charlieyou/cerberus/internal/state"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

type roundPrompts struct {
	System          []byte
	User            []byte
	ArtifactType    string
	ArtifactContent string
	ContextContent  string
	PeerBroadcast   []byte
	Root            string
	RunRoot         string
	RuntimeMode     string
	Iteration       int
	Round           int
	Consensus       aggregate.Mode
	FailurePriority int
}

type roundReviewerResult struct {
	Output reviewer.RawReviewerOutput
	Row    telemetry.ReviewerRow
	Failed bool
}

type roundSlotResult struct {
	Result roundReviewerResult
	Err    error
}

func runRound(ctx context.Context, slots []ReviewerSlot, spawner reviewer.Spawner, prompts roundPrompts) ([]roundReviewerResult, aggregate.Result, error) {
	if len(slots) == 0 {
		return nil, aggregate.Result{}, fmt.Errorf("review round requires at least one reviewer")
	}
	if spawner == nil {
		return nil, aggregate.Result{}, fmt.Errorf("reviewer spawner is nil")
	}
	iteration := firstPositive(prompts.Iteration, 1)
	round := firstPositive(prompts.Round, 1)

	slotResults := make([]roundSlotResult, len(slots))
	var wg sync.WaitGroup

	for i, slot := range slots {
		i, slot := i, slot
		wg.Add(1)
		go func() {
			defer wg.Done()

			system, user, err := promptsForSlot(slot, prompts)
			if err != nil {
				slotResults[i] = reviewerFailureSlotResult(prompts.RunRoot, iteration, round, slot, i, prompts.RuntimeMode, time.Now().UTC(), err)
				return
			}
			startedAt := time.Now().UTC()
			if err := writeReviewerEvent(prompts.RunRoot, telemetry.EventReviewerSpawned, slot, i, round, startedAt, nil); err != nil {
				slotResults[i] = roundSlotResult{Err: err}
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
				Iteration: iteration,
				Round:     round,
			})
			if err != nil {
				if ctx.Err() != nil && (errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)) {
					slotResults[i] = roundSlotResult{Err: err}
					return
				}
				slotResults[i] = reviewerFailureSlotResult(prompts.RunRoot, iteration, round, slot, i, prompts.RuntimeMode, startedAt, err)
				return
			}
			endedAt := time.Now().UTC()
			parsed := response.Parsed
			if parsed == nil {
				parsed, err = reviewer.Parse(response.Output)
				if err != nil {
					slotResults[i] = reviewerFailureSlotResult(prompts.RunRoot, iteration, round, slot, i, prompts.RuntimeMode, startedAt, err)
					return
				}
			}
			row, err := reviewerTelemetryRow(slot, i, prompts.RuntimeMode, response, parsed, startedAt, endedAt, prompts.FailurePriority, round)
			if err != nil {
				slotResults[i] = reviewerFailureSlotResult(prompts.RunRoot, iteration, round, slot, i, prompts.RuntimeMode, startedAt, err)
				return
			}
			if prompts.RunRoot != "" {
				if err := writeReviewerOutput(prompts.RunRoot, iteration, round, slot.ID, *parsed); err != nil {
					slotResults[i] = roundSlotResult{Err: withReviewerFailureEvent(prompts.RunRoot, slot, i, round, err)}
					return
				}
				if err := telemetry.WriteReviewerRow(prompts.RunRoot, iteration, round, &row); err != nil {
					slotResults[i] = roundSlotResult{Err: withReviewerFailureEvent(prompts.RunRoot, slot, i, round, err)}
					return
				}
			}
			if err := writeReviewerEvent(prompts.RunRoot, telemetry.EventReviewerCompleted, slot, i, round, endedAt, map[string]any{
				"verdict": row.Verdict,
			}); err != nil {
				slotResults[i] = roundSlotResult{Err: err}
				return
			}
			slotResults[i] = roundSlotResult{Result: roundReviewerResult{Output: *parsed, Row: row}}
		}()
	}

	wg.Wait()
	outputs := make([]roundReviewerResult, 0, len(slots))
	for _, slotResult := range slotResults {
		if slotResult.Err != nil {
			return nil, aggregate.Result{}, slotResult.Err
		}
		outputs = append(outputs, slotResult.Result)
	}
	result, err := aggregateRoundOutputs(outputs, prompts.Consensus, prompts.FailurePriority)
	if err != nil {
		return nil, aggregate.Result{}, err
	}
	return outputs, result, nil
}

func aggregateRoundOutputs(outputs []roundReviewerResult, consensus aggregate.Mode, failurePriority int) (aggregate.Result, error) {
	successful := make([]reviewer.RawReviewerOutput, 0, len(outputs))
	successfulIndexes := make([]int, 0, len(outputs))
	for i, output := range outputs {
		if output.Failed {
			continue
		}
		successful = append(successful, output.Output)
		successfulIndexes = append(successfulIndexes, i)
	}

	var result aggregate.Result
	if len(successful) == 0 {
		result = aggregate.Result{Verdict: aggregate.VerdictRequiresDecision}
	} else {
		var err error
		result, err = aggregate.Compute(successful, consensus, failurePriority)
		if err != nil {
			return aggregate.Result{}, err
		}
		for i := range result.Blockers {
			filteredIndex := result.Blockers[i].ReviewerIndex
			if filteredIndex < 0 || filteredIndex >= len(successfulIndexes) {
				return aggregate.Result{}, fmt.Errorf("aggregate blocker reviewer index %d out of range", filteredIndex)
			}
			result.Blockers[i].ReviewerIndex = successfulIndexes[filteredIndex]
		}
	}
	return result, nil
}

func reviewerFailureSlotResult(runRoot string, iteration, round int, slot ReviewerSlot, slotIndex int, runtimeMode string, startedAt time.Time, original error) roundSlotResult {
	if err := writeReviewerFailureEvent(runRoot, slot, slotIndex, round, original); err != nil {
		return roundSlotResult{Err: err}
	}
	endedAt := time.Now().UTC()
	output := failedReviewerOutput(slot, round, original)
	row := failedReviewerTelemetryRow(slot, slotIndex, runtimeMode, round, startedAt, endedAt)
	if runRoot != "" {
		if err := writeReviewerOutput(runRoot, iteration, round, slot.ID, output); err != nil {
			return roundSlotResult{Err: err}
		}
		if err := telemetry.WriteReviewerRow(runRoot, iteration, round, &row); err != nil {
			return roundSlotResult{Err: fmt.Errorf("write failed reviewer telemetry: %w", err)}
		}
	}
	return roundSlotResult{Result: roundReviewerResult{Output: output, Row: row, Failed: true}}
}

func failedReviewerOutput(slot ReviewerSlot, round int, original error) reviewer.RawReviewerOutput {
	confidence := 0.0
	roundValue := firstPositive(round, 1)
	strategy := (*string)(nil)
	if slot.Strategy != "" {
		value := slot.Strategy
		strategy = &value
	}
	reviewerID := firstNonEmpty(slot.ID, slot.Provider)
	return reviewer.RawReviewerOutput{
		Findings:          []reviewer.RawFinding{},
		Summary:           fmt.Sprintf("Reviewer %s failed: %v", reviewerID, original),
		OverallConfidence: &confidence,
		Strategy:          strategy,
		Round:             &roundValue,
		PeerResponsesSeen: []string{},
	}
}

func failedReviewerTelemetryRow(slot ReviewerSlot, slotIndex int, runtimeMode string, round int, startedAt, endedAt time.Time) telemetry.ReviewerRow {
	instanceIndex := reviewerInstanceIndex(slot, slotIndex)
	return telemetry.ReviewerRow{
		ReviewerID:        slot.ID,
		InstanceIndex:     instanceIndex,
		Provider:          slot.Provider,
		Model:             slot.Model,
		Strategy:          slot.Strategy,
		PersonaName:       personaName(slot.PersonaPath),
		Mode:              firstNonEmpty(slot.Mode, runtimeMode),
		Tokens:            telemetry.Tokens{},
		CostUSD:           0,
		PeerID:            fmt.Sprintf("peer_%d", instanceIndex),
		Verdict:           aggregate.VerdictRequiresDecision,
		OverallConfidence: 0,
		Round:             round,
		TimeToFinishMS:    endedAt.Sub(startedAt).Milliseconds(),
		StartedAt:         startedAt,
		EndedAt:           &endedAt,
	}
}

func writeReviewerOutput(runRoot string, iteration, round int, reviewerID string, output reviewer.RawReviewerOutput) error {
	data, err := json.MarshalIndent(output, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal failed reviewer output: %w", err)
	}
	data = append(data, '\n')
	return state.WriteReviewerOutput(runRoot, iteration, round, reviewerID, data)
}

func roundFailureCount(results []roundReviewerResult) int {
	failures := 0
	for _, result := range results {
		if result.Failed {
			failures++
		}
	}
	return failures
}

func activeReviewerCount(results []roundReviewerResult) int {
	return len(results) - roundFailureCount(results)
}

func reviewerFailureResolutionReason(results []roundReviewerResult) string {
	failures := roundFailureCount(results)
	if failures == 0 {
		return ""
	}
	if failures == 1 {
		return "1 reviewer failed; see reviewer logs"
	}
	return fmt.Sprintf("%d reviewers failed; see reviewer logs", failures)
}

func writeReviewerFailureEvent(runRoot string, slot ReviewerSlot, slotIndex int, round int, original error) error {
	if eventErr := writeReviewerEvent(runRoot, telemetry.EventReviewerFailed, slot, slotIndex, round, time.Now().UTC(), map[string]any{
		"error": original.Error(),
	}); eventErr != nil {
		return fmt.Errorf("%w; record reviewer failure event: %v", original, eventErr)
	}
	return nil
}

func withReviewerFailureEvent(runRoot string, slot ReviewerSlot, slotIndex int, round int, original error) error {
	if err := writeReviewerFailureEvent(runRoot, slot, slotIndex, round, original); err != nil {
		return err
	}
	return original
}

func writeReviewerEvent(runRoot string, eventName string, slot ReviewerSlot, slotIndex int, round int, at time.Time, extra map[string]any) error {
	if runRoot == "" {
		return nil
	}
	payload := map[string]any{
		"reviewer_id":    slot.ID,
		"instance_index": reviewerInstanceIndex(slot, slotIndex),
		"provider":       slot.Provider,
		"model":          slot.Model,
		"round":          firstPositive(round, 1),
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

func reviewerTelemetryRow(slot ReviewerSlot, slotIndex int, runtimeMode string, response reviewer.Response, output *reviewer.RawReviewerOutput, startedAt, endedAt time.Time, failurePriority int, requestRound int) (telemetry.ReviewerRow, error) {
	verdict := aggregate.VerdictForFindings(output.Findings, failurePriority)
	instanceIndex := reviewerInstanceIndex(slot, slotIndex)
	reviewerID := firstNonEmpty(response.ID, slot.ID)
	confidence := 0.5
	if output.OverallConfidence != nil {
		confidence = *output.OverallConfidence
	}
	round := firstPositive(requestRound, 1)

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
	artifactType := round.ArtifactType
	if artifactType == "" {
		artifactType = "code"
	}
	system, user, err := prompts.ComposeFromRootWithReplacements(root, roster.RosterSlot{
		Provider:    slot.Provider,
		Model:       slot.Model,
		Strategy:    slot.Strategy,
		PersonaPath: slot.PersonaPath,
		Mode:        slot.Mode,
	}, artifactType, artifactReplacements(artifactType, round.ArtifactContent, round.ContextContent))
	if err != nil {
		return nil, nil, err
	}
	if len(round.PeerBroadcast) > 0 {
		user, err = prompts.InjectPeerBroadcast(user, round.PeerBroadcast)
		if err != nil {
			return nil, nil, err
		}
	} else {
		user = bytes.ReplaceAll(user, []byte(prompts.PeerBroadcastMarker), nil)
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

func artifactReplacements(artifactType, content, context string) map[string]string {
	replacements := map[string]string{}
	if context != "" {
		replacements["CONTEXT"] = context
	}
	switch artifactType {
	case "plan":
		replacements["PLAN_CONTENT"] = content
	case "spec":
		replacements["SPEC_CONTENT"] = content
	case "ask":
		replacements["ASK_CONTENT"] = content
	case "epic-verify":
		replacements["EPIC_CONTEXT"] = content
	case "code":
		replacements["DIFF_CONTENT"] = content
	}
	return replacements
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

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func firstPositive(values ...int) int {
	for _, value := range values {
		if value > 0 {
			return value
		}
	}
	return 0
}

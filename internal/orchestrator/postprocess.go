package orchestrator

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"time"

	"github.com/charlieyou/cerberus/internal/aggregate"
	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/telemetry"
)

const postReviewDedupAgentID = "cerberus-dedup#1"
const postReviewDedupRound = 99

func maybeRunPostReviewDedup(ctx context.Context, postReviewer ReviewerSlot, spawner reviewer.Spawner, prompts roundPrompts, results []roundReviewerResult) ([]roundReviewerResult, aggregate.Result, bool, error) {
	if !postReviewDedupEnabled(prompts.ArtifactType) || spawner == nil {
		return results, aggregate.Result{}, false, nil
	}
	activeOutputs := make([]postReviewOutput, 0, len(results))
	findingCount := 0
	for _, result := range results {
		if result.Failed {
			continue
		}
		output := result.Output
		findingCount += len(output.Findings)
		activeOutputs = append(activeOutputs, postReviewOutput{
			ReviewerID: firstNonEmpty(output.InstanceID, result.Row.ReviewerID),
			Findings:   output.Findings,
		})
	}
	if len(activeOutputs) == 0 || findingCount == 0 {
		return results, aggregate.Result{}, false, nil
	}
	dedupSlot := normalizePostReviewSlot(postReviewer)

	input, err := json.MarshalIndent(postReviewRequest{
		ArtifactType:    prompts.ArtifactType,
		ArtifactContent: prompts.ArtifactContent,
		ContextContent:  prompts.ContextContent,
		UserPrompt:      string(prompts.User),
		FailurePriority: prompts.FailurePriority,
		Instruction:     "Return the final verified, deduplicated findings for this review gate. Use the candidate findings as inputs; do not invent new issues. Verify each candidate against the artifact/context/user prompt when available, drop unsupported candidates, merge duplicates that describe the same actionable issue, and keep distinct issues separate. When merging retained findings, preserve severity=blocking if any source finding was blocking, use the lowest numeric priority from the merged sources, and never make a retained finding less blocking unless you drop it entirely as unsupported. Return JSON only with exactly one top-level key: findings.",
		Outputs:         activeOutputs,
	}, "", "  ")
	if err != nil {
		return results, aggregate.Result{}, false, fmt.Errorf("marshal post-review dedup input: %w", err)
	}

	startedAt := time.Now().UTC()
	if err := writeReviewerEvent(prompts.RunRoot, telemetry.EventReviewerSpawned, dedupSlot, dedupSlot.InstanceIndex-1, postReviewDedupRound, startedAt, map[string]any{"post_review": "verify_dedup"}); err != nil {
		return results, aggregate.Result{}, false, err
	}
	response, err := spawner.Spawn(ctx, reviewer.Request{
		ID:        dedupSlot.ID,
		Provider:  dedupSlot.Provider,
		Model:     dedupSlot.Model,
		Effort:    dedupSlot.Effort,
		Mode:      prompts.RuntimeMode,
		System:    []byte(postReviewDedupSystemPrompt),
		User:      input,
		Root:      prompts.Root,
		RunRoot:   prompts.RunRoot,
		Iteration: firstPositive(prompts.Iteration, 1),
		Round:     postReviewDedupRound,
	})
	if err != nil {
		return results, aggregate.Result{}, false, withReviewerFailureEvent(prompts.RunRoot, dedupSlot, dedupSlot.InstanceIndex-1, postReviewDedupRound, err)
	}
	endedAt := time.Now().UTC()
	parsed := response.Parsed
	if parsed == nil {
		parsed, err = reviewer.Parse(response.Output)
		if err != nil {
			return results, aggregate.Result{}, false, withReviewerFailureEvent(prompts.RunRoot, dedupSlot, dedupSlot.InstanceIndex-1, postReviewDedupRound, err)
		}
	}
	row, err := reviewerTelemetryRow(dedupSlot, dedupSlot.InstanceIndex-1, prompts.RuntimeMode, response, parsed, startedAt, endedAt, prompts.FailurePriority, postReviewDedupRound)
	if err != nil {
		return results, aggregate.Result{}, false, withReviewerFailureEvent(prompts.RunRoot, dedupSlot, dedupSlot.InstanceIndex-1, postReviewDedupRound, err)
	}
	if prompts.RunRoot != "" {
		if err := writeReviewerOutput(prompts.RunRoot, firstPositive(prompts.Iteration, 1), postReviewDedupRound, dedupSlot.ID, *parsed); err != nil {
			return results, aggregate.Result{}, false, withReviewerFailureEvent(prompts.RunRoot, dedupSlot, dedupSlot.InstanceIndex-1, postReviewDedupRound, err)
		}
		if err := telemetry.WriteReviewerRow(prompts.RunRoot, firstPositive(prompts.Iteration, 1), postReviewDedupRound, &row); err != nil {
			return results, aggregate.Result{}, false, withReviewerFailureEvent(prompts.RunRoot, dedupSlot, dedupSlot.InstanceIndex-1, postReviewDedupRound, err)
		}
	}
	if err := writeReviewerEvent(prompts.RunRoot, telemetry.EventReviewerCompleted, dedupSlot, dedupSlot.InstanceIndex-1, postReviewDedupRound, endedAt, map[string]any{
		"verdict":     row.Verdict,
		"post_review": "verify_dedup",
	}); err != nil {
		return results, aggregate.Result{}, false, err
	}
	postResults := []roundReviewerResult{{Output: *parsed, Row: row}}
	postAggregate, err := aggregateRoundOutputs(postResults, prompts.Consensus, prompts.FailurePriority)
	if err != nil {
		return results, aggregate.Result{}, false, err
	}
	return postResults, postAggregate, true, nil
}

func normalizePostReviewSlot(slot ReviewerSlot) ReviewerSlot {
	if slot.Provider == "" {
		slot.Provider = "codex"
	}
	if slot.Model == "" {
		if model, ok := config.DefaultModelForProvider(slot.Provider); ok {
			slot.Model = model
		}
	}
	if slot.Effort == "" {
		slot.Effort = "low"
	}
	slot.ID = postReviewDedupAgentID
	slot.Strategy = "independent-verifier"
	slot.PersonaPath = ""
	if slot.InstanceIndex <= 0 {
		slot.InstanceIndex = 1
	}
	return slot
}

func preflightPostReviewSlot(artifactType string, slot ReviewerSlot) (ReviewerSlot, error) {
	if !postReviewDedupEnabled(artifactType) {
		return slot, nil
	}
	slot = normalizePostReviewSlot(slot)
	switch slot.Provider {
	case "claude", "codex", "gemini":
	default:
		return ReviewerSlot{}, fmt.Errorf("post-reviewer preflight: unsupported provider %q", slot.Provider)
	}
	if slot.Model == "" {
		return ReviewerSlot{}, fmt.Errorf("post-reviewer preflight: model is required")
	}
	if slot.Effort == "" {
		return ReviewerSlot{}, fmt.Errorf("post-reviewer preflight: effort is required")
	}
	if _, err := exec.LookPath(slot.Provider); err != nil {
		return ReviewerSlot{}, fmt.Errorf("post-reviewer preflight: provider CLI %q is not available on PATH", slot.Provider)
	}
	return slot, nil
}

func postReviewDedupEnabled(artifactType string) bool {
	switch artifactType {
	case "", "code", "epic-verify":
		return true
	default:
		return false
	}
}

type postReviewRequest struct {
	ArtifactType    string             `json:"artifact_type"`
	ArtifactContent string             `json:"artifact_content,omitempty"`
	ContextContent  string             `json:"context_content,omitempty"`
	UserPrompt      string             `json:"user_prompt,omitempty"`
	FailurePriority int                `json:"failure_priority"`
	Instruction     string             `json:"instruction"`
	Outputs         []postReviewOutput `json:"outputs"`
}

type postReviewOutput struct {
	ReviewerID string                `json:"reviewer_id"`
	Findings   []reviewer.RawFinding `json:"findings"`
}

const postReviewDedupSystemPrompt = `## Role
You are the Cerberus post-review verification and deduplication agent.

You run after the normal code-review or epic-verification agents. Your job is to produce the final findings list for the review gate by verifying and deduplicating the candidate findings you receive.

## Inputs
The user message is JSON containing:
- artifact_type: "code" or "epic-verify".
- artifact_content, context_content, and user_prompt: source material you may use to verify candidates.
- failure_priority: numeric priority threshold where lower/equal priorities are blocking for the gate.
- outputs: reviewer_id plus findings from the upstream reviewers/verifiers.

## Verification and Deduplication Rules
- Do not search for or add brand-new issues. Only keep, drop, or merge candidate findings.
- Drop a candidate finding when its claim is unsupported by the provided artifact/context/prompt or when the evidence is too ambiguous to act on.
- Treat findings as duplicates when they describe the same actionable defect or unmet criterion, even if their titles differ.
- Keep distinct actionable issues separate, even if they occur in the same file or acceptance criterion.
- When merging duplicates, write one concise finding using the strongest evidence from the source findings.
- Preserve the most severe blocking semantics from merged sources: if any source finding has severity "blocking", the merged finding must also have severity "blocking".
- Preserve the highest-risk priority from merged sources: use the lowest numeric priority value among the merged findings.
- Never downgrade a retained finding from blocking to non-blocking. If a blocking candidate is unsupported, drop it instead of weakening it.
- Use null for file_path, line_start, or line_end only when no candidate provides a supported location.

## Output Format
Return valid JSON only. Do not include markdown fences, commentary, verdict, summary, or any top-level key other than "findings".

Schema:
{
  "findings": [
    {
      "title": "[P1] Short actionable title",
      "body": "Why the retained issue is supported and what must be fixed.",
      "severity": "blocking",
      "priority": 1,
      "file_path": "path/to/file.go",
      "line_start": 10,
      "line_end": 12,
      "confidence": 0.85
    }
  ]
}

If no candidate finding remains supported after verification and deduplication, return exactly {"findings": []}.

## Examples
<example>
Input candidates: two reviewers report the same nil-pointer bug at the same call site; one marks it P1/blocking and one marks it P3.
Output: one finding for that bug with priority 1 and severity "blocking".
</example>

<example>
Input candidates: one reviewer reports a missing epic criterion, but artifact_content shows the criterion implemented and context_content cites the implementation.
Output: omit that finding.
</example>`

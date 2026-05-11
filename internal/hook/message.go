package hook

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/state"
)

func stopHookResponse(result *PollResult) (string, error) {
	if result == nil || result.Missing || result.Gate == nil || result.Gate.Status != state.StatusResolved {
		return "", nil
	}
	claimed, err := claimStopMessageEmission(result.RunRoot)
	if err != nil {
		return "", err
	}
	if !claimed {
		return "", nil
	}
	message := resolvedGateMessage(result.RunRoot, result.Gate)
	return claudeStyleBlockResponse(message)
}

func claimStopMessageEmission(runRoot string) (bool, error) {
	if runRoot == "" {
		return false, fmt.Errorf("run root is required")
	}
	file, err := os.OpenFile(state.StopMessageMarkerPath(runRoot), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if errors.Is(err, os.ErrExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("create stop message marker: %w", err)
	}
	defer file.Close()
	data, err := json.MarshalIndent(map[string]string{
		"emitted_at": time.Now().UTC().Format(time.RFC3339Nano),
	}, "", "  ")
	if err != nil {
		return false, fmt.Errorf("marshal stop message marker: %w", err)
	}
	data = append(data, '\n')
	if _, err := file.Write(data); err != nil {
		return false, fmt.Errorf("write stop message marker: %w", err)
	}
	return true, nil
}

func claudeStyleBlockResponse(reason string) (string, error) {
	data, err := json.Marshal(map[string]string{
		"decision": "block",
		"reason":   reason,
	})
	if err != nil {
		return "", fmt.Errorf("marshal stop hook response: %w", err)
	}
	return string(data) + "\n", nil
}

func resolvedGateMessage(runRoot string, gate *state.GateState) string {
	verdict := state.VerdictRequiresDecision
	if gate != nil && gate.Verdict != nil && *gate.Verdict != "" {
		verdict = *gate.Verdict
	}
	findings, summaries := reviewerOutputsSummary(runRoot)

	var b strings.Builder
	switch verdict {
	case state.VerdictPass:
		b.WriteString("## Review Complete\n\n")
		b.WriteString("**Review passed.**\n\n")
		if findings != "" {
			b.WriteString("## Review Findings\n\n")
			b.WriteString(findings)
			b.WriteString("\n\n## Context Preservation Requirement\n\n")
			b.WriteString("If you investigate or address advisory findings, you MUST delegate that work to subagents so the main thread preserves context for coordination, edits, verification, and the final summary.\n\n")
			b.WriteString("Please address any advisory issues above, then provide a brief summary of the review outcome. You may stop after that summary.")
		} else {
			b.WriteString("Please provide a brief summary of the review outcome, then you may stop.")
		}
	case state.VerdictFail, state.VerdictRequiresDecision:
		b.WriteString("## Revision Required\n\n")
		if gate != nil && gate.ResolutionReason != "" {
			b.WriteString("**Reason:** ")
			b.WriteString(gate.ResolutionReason)
			b.WriteString("\n\n")
		} else {
			b.WriteString("**Review did not pass.** Address the findings below before stopping.\n\n")
		}
		if findings != "" {
			b.WriteString("## Review Findings\n\n")
			b.WriteString(findings)
			b.WriteString("\n\n")
		}
		if summaries != "" {
			b.WriteString("## Reviewer Summaries\n\n")
			b.WriteString(summaries)
			b.WriteString("\n\n")
		}
		b.WriteString("## Context Preservation Requirement\n\n")
		b.WriteString("You MUST use subagents for investigation, debugging, and review follow-up before making or validating fixes. Keep the main thread focused on coordination, applying the chosen edits, running verification, and summarizing the outcome.\n\n")
		b.WriteString("You MUST fix the blocking issues above before stopping. After making changes, run Cerberus review again or explain why the remaining issues are safe to proceed with.")
	default:
		b.WriteString("## Review Gate Resolved\n\n")
		b.WriteString("Cerberus resolved with verdict: ")
		b.WriteString(verdict)
		b.WriteString(". Please summarize the review outcome before stopping.")
	}
	return b.String()
}

func reviewerOutputsSummary(runRoot string) (string, string) {
	outputs := readReviewerOutputs(runRoot)
	if len(outputs) == 0 {
		return "", ""
	}
	var findings strings.Builder
	var summaries strings.Builder
	for _, output := range outputs {
		if output.Summary != "" {
			summaries.WriteString("- **")
			summaries.WriteString(output.InstanceID)
			summaries.WriteString("**: ")
			summaries.WriteString(output.Summary)
			summaries.WriteByte('\n')
		}
		for _, finding := range output.Findings {
			findings.WriteString("- ")
			findings.WriteString(findingLabel(finding))
			findings.WriteString(" **")
			findings.WriteString(output.InstanceID)
			findings.WriteString("**: ")
			findings.WriteString(finding.Title)
			if loc := findingLocation(finding); loc != "" {
				findings.WriteString(" (`")
				findings.WriteString(loc)
				findings.WriteString("`)")
			}
			if finding.Body != "" {
				findings.WriteString(" — ")
				findings.WriteString(finding.Body)
			}
			findings.WriteByte('\n')
		}
	}
	return strings.TrimSpace(findings.String()), strings.TrimSpace(summaries.String())
}

func readReviewerOutputs(runRoot string) []reviewer.RawReviewerOutput {
	var paths []string
	root := state.IterationsDir(runRoot)
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry == nil || entry.IsDir() || entry.Name() != "output.json" {
			return nil
		}
		paths = append(paths, path)
		return nil
	})
	sort.Strings(paths)

	outputs := make([]reviewer.RawReviewerOutput, 0, len(paths))
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var output reviewer.RawReviewerOutput
		if err := json.Unmarshal(data, &output); err != nil {
			continue
		}
		output.InstanceID = reviewerIDFromOutputPath(path)
		outputs = append(outputs, output)
	}
	return outputs
}

func reviewerIDFromOutputPath(path string) string {
	dir := filepath.Base(filepath.Dir(path))
	if dir == "." || dir == string(filepath.Separator) || dir == "" {
		return "reviewer"
	}
	return dir
}

func findingLabel(finding reviewer.RawFinding) string {
	var parts []string
	if finding.Severity != nil && *finding.Severity != "" {
		parts = append(parts, strings.ToUpper(*finding.Severity))
	}
	if finding.Priority != nil {
		parts = append(parts, fmt.Sprintf("P%d", *finding.Priority))
	}
	if len(parts) == 0 {
		return "[finding]"
	}
	return "[" + strings.Join(parts, "/") + "]"
}

func findingLocation(finding reviewer.RawFinding) string {
	if finding.FilePath == nil || *finding.FilePath == "" {
		return ""
	}
	if finding.LineStart != nil && *finding.LineStart > 0 {
		if finding.LineEnd != nil && *finding.LineEnd > 0 && *finding.LineEnd != *finding.LineStart {
			return fmt.Sprintf("%s:%d-%d", *finding.FilePath, *finding.LineStart, *finding.LineEnd)
		}
		return fmt.Sprintf("%s:%d", *finding.FilePath, *finding.LineStart)
	}
	return *finding.FilePath
}

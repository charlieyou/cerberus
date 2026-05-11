package reviewer

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

// Parse strictly decodes reviewer stdout as JSON and validates the raw verdict.
func Parse(stdout []byte) (*RawReviewerOutput, error) {
	if len(stdout) == 0 {
		return nil, fmt.Errorf("reviewer stdout is empty")
	}

	output, err := parseRaw(stdout)
	if err != nil {
		providerOutput, ok, providerErr := parseProviderOutput(stdout)
		if providerErr != nil {
			return nil, providerErr
		}
		if !ok {
			return nil, err
		}
		if providerOutput == nil {
			return nil, fmt.Errorf("parse reviewer JSON: provider output parser returned no reviewer output")
		}
		output = providerOutput
	}
	if err := validate(output); err != nil {
		return nil, err
	}
	return output, nil
}

func parseProviderOutput(stdout []byte) (*RawReviewerOutput, bool, error) {
	if output, ok, err := parseClaudeResult(stdout); ok {
		return output, true, err
	}
	if output, ok, err := parseGeminiResponse(stdout); ok {
		return output, true, err
	}
	if output, ok, err := parseCodexJSONL(stdout); ok {
		return output, true, err
	}
	return nil, false, nil
}

func parseClaudeResult(stdout []byte) (*RawReviewerOutput, bool, error) {
	var wrapper struct {
		Result string `json:"result"`
	}
	if err := json.Unmarshal(stdout, &wrapper); err != nil || wrapper.Result == "" {
		return nil, false, nil
	}
	output, err := parseRawOrEmbedded([]byte(wrapper.Result))
	if err != nil {
		return nil, true, fmt.Errorf("parse claude result JSON: %w", err)
	}
	return output, true, nil
}

func parseGeminiResponse(stdout []byte) (*RawReviewerOutput, bool, error) {
	var wrapper struct {
		Response string `json:"response"`
	}
	if err := json.Unmarshal(stdout, &wrapper); err != nil || wrapper.Response == "" {
		return nil, false, nil
	}
	output, err := parseRaw([]byte(stripMarkdownFence(wrapper.Response)))
	if err != nil {
		return nil, true, fmt.Errorf("parse gemini response JSON: %w", err)
	}
	return output, true, nil
}

func parseCodexJSONL(stdout []byte) (*RawReviewerOutput, bool, error) {
	decoder := json.NewDecoder(bytes.NewReader(stdout))
	var lastAgentMessage string
	seenEvent := false
	for {
		var event struct {
			Type string `json:"type"`
			Item struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"item"`
		}
		if err := decoder.Decode(&event); err != nil {
			if err == io.EOF {
				break
			}
			if seenEvent {
				return nil, true, fmt.Errorf("parse codex JSONL: %w", err)
			}
			return nil, false, nil
		}
		if event.Type == "" {
			return nil, false, nil
		}
		seenEvent = true
		if event.Type == "item.completed" && event.Item.Type == "agent_message" && strings.TrimSpace(event.Item.Text) != "" {
			lastAgentMessage = event.Item.Text
		}
	}
	if lastAgentMessage == "" {
		if seenEvent {
			return nil, true, fmt.Errorf("parse codex JSONL: no completed agent_message found")
		}
		return nil, false, nil
	}
	output, err := parseRaw([]byte(stripMarkdownFence(lastAgentMessage)))
	if err != nil {
		return nil, true, fmt.Errorf("parse codex agent_message JSON: %w", err)
	}
	return output, true, nil
}

func parseRawOrEmbedded(stdout []byte) (*RawReviewerOutput, error) {
	trimmed := []byte(stripMarkdownFence(string(stdout)))
	if output, err := parseRaw(trimmed); err == nil {
		return output, nil
	}
	var lastOutput *RawReviewerOutput
	var lastCandidateErr error
	for offset, char := range trimmed {
		if char != '{' {
			continue
		}
		decoder := json.NewDecoder(bytes.NewReader(trimmed[offset:]))
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			continue
		}
		if !looksLikeReviewerObject(raw) {
			continue
		}
		output, err := parseRaw(raw)
		if err == nil {
			lastOutput = output
		} else {
			lastCandidateErr = err
		}
	}
	if lastOutput != nil {
		return lastOutput, nil
	}
	if lastCandidateErr != nil {
		return nil, lastCandidateErr
	}
	return parseRaw(trimmed)
}

func looksLikeReviewerObject(raw []byte) bool {
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err != nil {
		return false
	}
	for _, key := range []string{"findings", "verdict", "summary"} {
		if _, ok := object[key]; ok {
			return true
		}
	}
	return false
}

func stripMarkdownFence(text string) string {
	trimmed := strings.TrimSpace(text)
	if !strings.HasPrefix(trimmed, "```") {
		return trimmed
	}
	lines := strings.Split(trimmed, "\n")
	if len(lines) < 2 {
		return trimmed
	}
	if strings.HasPrefix(strings.TrimSpace(lines[len(lines)-1]), "```") {
		lines = lines[1 : len(lines)-1]
	} else {
		lines = lines[1:]
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func parseRaw(stdout []byte) (*RawReviewerOutput, error) {
	var output RawReviewerOutput
	decoder := json.NewDecoder(bytes.NewReader(stdout))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&output); err != nil {
		return nil, fmt.Errorf("parse reviewer JSON: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return nil, fmt.Errorf("parse reviewer JSON: trailing data")
	}
	if err := validateRequiredFields(stdout); err != nil {
		return nil, err
	}
	return &output, nil
}

func validateRequiredFields(stdout []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(stdout, &raw); err != nil {
		return fmt.Errorf("parse reviewer JSON fields: %w", err)
	}
	for _, key := range []string{"findings", "verdict", "summary"} {
		if _, ok := raw[key]; !ok {
			return fmt.Errorf("reviewer %s is required", key)
		}
	}
	for _, key := range []string{"summary"} {
		if bytes.Equal(bytes.TrimSpace(raw[key]), []byte("null")) {
			return fmt.Errorf("reviewer %s is required", key)
		}
	}

	var findings []map[string]json.RawMessage
	if err := json.Unmarshal(raw["findings"], &findings); err != nil {
		return fmt.Errorf("reviewer findings must be an array: %w", err)
	}
	for index, finding := range findings {
		for _, key := range []string{"title", "body", "priority", "file_path", "line_start", "line_end", "confidence"} {
			if _, ok := finding[key]; !ok {
				return fmt.Errorf("reviewer findings[%d].%s is required", index, key)
			}
		}
		if bytes.Equal(bytes.TrimSpace(finding["priority"]), []byte("null")) {
			return fmt.Errorf("reviewer findings[%d].priority is required", index)
		}
		for _, key := range []string{"title", "body"} {
			if bytes.Equal(bytes.TrimSpace(finding[key]), []byte("null")) {
				return fmt.Errorf("reviewer findings[%d].%s is required", index, key)
			}
		}
	}
	return nil
}

func validate(output *RawReviewerOutput) error {
	switch output.Verdict {
	case "PASS", "FAIL", "NEEDS_WORK":
	default:
		return fmt.Errorf("reviewer verdict %q is invalid", output.Verdict)
	}
	if output.Findings == nil {
		return fmt.Errorf("reviewer findings is required")
	}
	return nil
}

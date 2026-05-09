package reviewer

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
)

// Parse strictly decodes reviewer stdout as JSON and validates the raw verdict.
func Parse(stdout []byte) (*RawReviewerOutput, error) {
	if len(stdout) == 0 {
		return nil, fmt.Errorf("reviewer stdout is empty")
	}

	output, err := parseRaw(stdout)
	if err != nil {
		var wrapper struct {
			Result string `json:"result"`
		}
		if wrapperErr := json.Unmarshal(stdout, &wrapper); wrapperErr != nil || wrapper.Result == "" {
			return nil, err
		}
		output, err = parseRaw([]byte(wrapper.Result))
		if err != nil {
			return nil, fmt.Errorf("parse claude result JSON: %w", err)
		}
	}
	if err := validate(output); err != nil {
		return nil, err
	}
	return output, nil
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
	for _, key := range []string{"findings", "verdict", "summary", "overall_confidence", "strategy", "round", "peer_responses_seen"} {
		if _, ok := raw[key]; !ok {
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

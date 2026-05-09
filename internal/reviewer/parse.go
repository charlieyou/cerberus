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

	var output RawReviewerOutput
	decoder := json.NewDecoder(bytes.NewReader(stdout))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&output); err != nil {
		return nil, fmt.Errorf("parse reviewer JSON: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return nil, fmt.Errorf("parse reviewer JSON: trailing data")
	}
	switch output.Verdict {
	case "PASS", "FAIL", "NEEDS_WORK":
	default:
		return nil, fmt.Errorf("reviewer verdict %q is invalid", output.Verdict)
	}
	if output.Findings == nil {
		return nil, fmt.Errorf("reviewer findings is required")
	}
	return &output, nil
}

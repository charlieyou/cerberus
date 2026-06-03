package generate

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

// extractDraftText converts a provider's raw stdout into the human-readable
// draft markdown written to draft.md. Each provider CLI wraps its output
// differently; draft.md should hold the draft itself, not the wrapper. The
// untouched stdout is still preserved separately in raw.json.
//
//   - codex `exec --json` emits a JSONL event stream (thread.started,
//     turn.started, command_execution, item.completed, …). The draft is the
//     text of the final completed agent_message; the rest — including
//     multi-hundred-KB command_execution events — is transcript noise.
//   - claude `--output-format json` emits a single result envelope; the draft
//     is the .result string.
//   - gemini `--output-format json` emits a single response envelope; the draft
//     is the .response string.
//
// Output that does not match the provider's expected wrapper (such as the
// plain-text mocks used in tests) passes through unchanged.
func extractDraftText(provider string, stdout []byte) ([]byte, error) {
	switch provider {
	case "codex":
		text, isStream, err := codexAgentMessage(stdout)
		if err != nil {
			return nil, err
		}
		if !isStream {
			return stdout, nil
		}
		return text, nil
	case "claude":
		if text, ok := jsonStringField(stdout, "result"); ok {
			return text, nil
		}
		return stdout, nil
	case "gemini":
		if text, ok := jsonStringField(stdout, "response"); ok {
			return text, nil
		}
		return stdout, nil
	default:
		return stdout, nil
	}
}

// jsonStringField reports whether stdout is a single JSON object carrying the
// named string field, and if so returns its value. A present-but-empty field is
// still recognized (returns "", true) so the caller's empty-draft guard can
// reject it; an absent field or non-JSON input is not recognized, leaving the
// caller to fall back to the raw bytes.
func jsonStringField(stdout []byte, field string) ([]byte, bool) {
	trimmed := bytes.TrimSpace(stdout)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return nil, false
	}
	var wrapper map[string]json.RawMessage
	if err := json.Unmarshal(trimmed, &wrapper); err != nil {
		return nil, false
	}
	raw, ok := wrapper[field]
	if !ok {
		return nil, false
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, false
	}
	return []byte(value), true
}

// codexAgentMessage scans a codex JSONL event stream and returns the text of
// the last completed agent_message. isStream reports whether stdout was a
// recognizable codex event stream at all; when false the caller falls back to
// the raw bytes rather than treating a missing message as an error.
func codexAgentMessage(stdout []byte) (text []byte, isStream bool, err error) {
	decoder := json.NewDecoder(bytes.NewReader(stdout))
	var lastMessage string
	seenEvent := false
	for {
		var event struct {
			Type string `json:"type"`
			Item struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"item"`
		}
		if decodeErr := decoder.Decode(&event); decodeErr != nil {
			if decodeErr == io.EOF {
				break
			}
			// A decode failure before any event means this is not a codex event
			// stream (plain text, or a single JSON object): fall back to the raw
			// bytes. A failure after valid events means the stream was truncated
			// mid-flight — keep whatever agent_message we already captured rather
			// than discard a usable draft.
			if !seenEvent {
				return nil, false, nil
			}
			break
		}
		if event.Type == "" {
			return nil, false, nil
		}
		seenEvent = true
		if event.Type == "item.completed" && event.Item.Type == "agent_message" && strings.TrimSpace(event.Item.Text) != "" {
			lastMessage = event.Item.Text
		}
	}
	if !seenEvent {
		return nil, false, nil
	}
	if strings.TrimSpace(lastMessage) == "" {
		return nil, true, fmt.Errorf("parse codex output: no completed agent_message found in event stream")
	}
	return []byte(lastMessage), true, nil
}

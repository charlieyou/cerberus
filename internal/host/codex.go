package host

import (
	"fmt"
	"path/filepath"

	"github.com/charlieyou/cerberus/internal/config"
)

// CodexHost resolves state and hook identity for the Codex CLI host.
type CodexHost struct{}

// NewCodexHost returns the first-class Codex host adapter.
func NewCodexHost() CodexHost {
	return CodexHost{}
}

func (CodexHost) Name() string {
	return "codex"
}

func (CodexHost) StateRoot(env *config.Env) (string, error) {
	return adapter{name: "codex"}.projectStateRoot(env, ".codex")
}

func (CodexHost) ProjectKey(env *config.Env) (string, error) {
	return adapter{name: "codex"}.ProjectKey(env)
}

func (CodexHost) ResolveSessionID(payload []byte) (string, error) {
	fields, err := decodeCodexPayloadFields(payload)
	if err != nil {
		return "", err
	}
	if fields.SessionID == "" {
		return "", fmt.Errorf("Codex session_id is required")
	}
	return fields.SessionID, nil
}

func (CodexHost) TranscriptPath(payload []byte) (string, error) {
	fields, err := decodeCodexPayloadFields(payload)
	if err != nil {
		return "", err
	}
	transcriptPath := firstNonEmpty(fields.TranscriptPath, fields.Transcript)
	if transcriptPath == "" {
		return "", fmt.Errorf("Codex transcript_path is required")
	}
	if !filepath.IsAbs(transcriptPath) {
		return "", fmt.Errorf("Codex transcript_path must be absolute")
	}
	return transcriptPath, nil
}

type codexPayloadFields struct {
	SessionID      string `json:"session_id"`
	TranscriptPath string `json:"transcript_path"`
	Transcript     string `json:"transcript"`
}

func decodeCodexPayloadFields(payload []byte) (codexPayloadFields, error) {
	var fields codexPayloadFields
	if err := decodePayloadFields(payload, &fields, "codex"); err != nil {
		return codexPayloadFields{}, err
	}
	return fields, nil
}

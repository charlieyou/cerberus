package config

import "os"

const (
	DefaultClaudeModel = "claude-opus-4-7"
	DefaultCodexModel  = "gpt-5.5"
	DefaultGeminiModel = "gemini-3.1-pro"
)

// Env contains the Cerberus environment contract consumed by v2 commands.
type Env struct {
	Root           string
	Host           string
	RunKey         string
	SessionID      string
	StateRoot      string
	ProjectKey     string
	TranscriptPath string
}

// Resolve reads the CERBERUS_* environment contract.
func Resolve() *Env {
	root := os.Getenv("CERBERUS_ROOT")
	if root == "" {
		root = os.Getenv("CLAUDE_PLUGIN_ROOT")
	}
	runKey := os.Getenv("CERBERUS_RUN_KEY")
	if runKey == "" {
		runKey = os.Getenv("REVIEW_GATE_SESSION_KEY")
	}

	return &Env{
		Root:           root,
		Host:           os.Getenv("CERBERUS_HOST"),
		RunKey:         runKey,
		SessionID:      os.Getenv("CERBERUS_SESSION_ID"),
		StateRoot:      os.Getenv("CERBERUS_STATE_ROOT"),
		ProjectKey:     os.Getenv("CERBERUS_PROJECT_KEY"),
		TranscriptPath: os.Getenv("CERBERUS_TRANSCRIPT_PATH"),
	}
}

// DefaultModelForProvider returns the built-in model for a supported provider.
func DefaultModelForProvider(provider string) (string, bool) {
	switch provider {
	case "claude":
		return DefaultClaudeModel, true
	case "codex":
		return DefaultCodexModel, true
	case "gemini":
		return DefaultGeminiModel, true
	default:
		return "", false
	}
}

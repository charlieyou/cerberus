package config

import "os"

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

	return &Env{
		Root:           root,
		Host:           os.Getenv("CERBERUS_HOST"),
		RunKey:         os.Getenv("CERBERUS_RUN_KEY"),
		SessionID:      os.Getenv("CERBERUS_SESSION_ID"),
		StateRoot:      os.Getenv("CERBERUS_STATE_ROOT"),
		ProjectKey:     os.Getenv("CERBERUS_PROJECT_KEY"),
		TranscriptPath: os.Getenv("CERBERUS_TRANSCRIPT_PATH"),
	}
}

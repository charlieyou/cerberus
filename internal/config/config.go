package config

import (
	"os"
	"path/filepath"
	"strings"
)

const (
	DefaultClaudeModel = "opus"
	ClaudeMaxModeModel = "fable"
	DefaultCodexModel  = "gpt-5.5"
	DefaultGeminiModel = "gemini-3.1-pro-preview"
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
	pluginRoot := os.Getenv("PLUGIN_ROOT")
	claudePluginRoot := os.Getenv("CLAUDE_PLUGIN_ROOT")
	codexThreadID := os.Getenv("CODEX_THREAD_ID")
	claudeSessionID := os.Getenv("CLAUDE_SESSION_ID")
	host := inferHost(pluginRoot, claudePluginRoot, codexThreadID, claudeSessionID, os.Getenv("CLAUDE_SKILL_DIR"))
	if host == "" {
		host = normalizeHost(os.Getenv("CERBERUS_HOST"))
	}
	root := os.Getenv("CERBERUS_ROOT")
	if root == "" {
		root = pluginRootForHost(host, pluginRoot, claudePluginRoot)
	}
	if root == "" && host == "codex" {
		if cachedRoot, err := ReadCodexPluginRootCache(codexThreadID); err == nil {
			root = cachedRoot
		}
	}
	runKey := os.Getenv("CERBERUS_RUN_KEY")
	if runKey == "" {
		runKey = os.Getenv("REVIEW_GATE_SESSION_KEY")
	}
	sessionID := os.Getenv("CERBERUS_SESSION_ID")
	if host == "codex" && codexThreadID != "" {
		sessionID = codexThreadID
	}

	return &Env{
		Root:           root,
		Host:           host,
		RunKey:         runKey,
		SessionID:      sessionID,
		StateRoot:      os.Getenv("CERBERUS_STATE_ROOT"),
		ProjectKey:     os.Getenv("CERBERUS_PROJECT_KEY"),
		TranscriptPath: os.Getenv("CERBERUS_TRANSCRIPT_PATH"),
	}
}

func normalizeHost(host string) string {
	if host == "claude-code" {
		return "claude"
	}
	return host
}

func inferHost(pluginRoot, claudePluginRoot, codexThreadID, claudeSessionID, claudeSkillDir string) string {
	switch {
	case codexThreadID != "" || pluginRoot != "":
		return "codex"
	case claudeSessionID != "" || claudePluginRoot != "" || claudeSkillDir != "":
		return "claude"
	default:
		return ""
	}
}

func pluginRootForHost(host, pluginRoot, claudePluginRoot string) string {
	if host == "codex" {
		return pluginRoot
	}
	if claudePluginRoot != "" {
		return claudePluginRoot
	}
	return pluginRoot
}

func preferredHomeDir() (string, error) {
	if home := os.Getenv("HOME"); home != "" {
		return home, nil
	}
	if home := os.Getenv("USERPROFILE"); home != "" {
		return home, nil
	}
	return os.UserHomeDir()
}

// CodexPluginRootCachePath returns the Codex session-scoped plugin-root bridge path.
func CodexPluginRootCachePath(sessionID string) (string, error) {
	home, err := preferredHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".codex", "cerberus", "sessions", sessionID, "plugin-root"), nil
}

// WriteCodexPluginRootCache records the plugin root for later Codex skill Bash snippets.
func WriteCodexPluginRootCache(sessionID, root string) error {
	if sessionID == "" || root == "" {
		return nil
	}
	path, err := CodexPluginRootCachePath(sessionID)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(root+"\n"), 0o644)
}

// ReadCodexPluginRootCache reads the plugin root written by Codex hooks.
func ReadCodexPluginRootCache(sessionID string) (string, error) {
	if sessionID == "" {
		return "", os.ErrNotExist
	}
	path, err := CodexPluginRootCachePath(sessionID)
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
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

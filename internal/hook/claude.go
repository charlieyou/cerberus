package hook

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/host"
	"github.com/charlieyou/cerberus/internal/state"
)

type claudePayload struct {
	SessionID      string `json:"session_id"`
	TranscriptPath string `json:"transcript_path"`
	Transcript     string `json:"transcript"`
	CWD            string `json:"cwd"`
}

func HandleClaudeStop(stdinPayload []byte, env *config.Env) error {
	_, runRoot, err := resolveHookRun(stdinPayload, env)
	if err != nil {
		return err
	}
	return PollGateState(state.GateStatePath(runRoot), PollIntervalSeconds*time.Second, MaxWaitSeconds*time.Second)
}

func HandleClaudeSessionStart(stdinPayload []byte, env *config.Env) error {
	resolved, runRoot, err := resolveHookRun(stdinPayload, env)
	if err != nil {
		return err
	}
	if err := state.EnsureRunDir(runRoot); err != nil {
		return err
	}

	data, err := json.MarshalIndent(map[string]string{
		"run_key":         resolved.RunKey,
		"session_id":      resolved.SessionID,
		"transcript_path": resolved.TranscriptPath,
	}, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal claude session state: %w", err)
	}
	data = append(data, '\n')
	if err := os.WriteFile(filepath.Join(runRoot, "session.json"), data, 0o644); err != nil {
		return fmt.Errorf("write claude session state: %w", err)
	}
	if err := state.WriteSessionCache(state.SessionCachePath(resolved.StateRoot, resolved.ProjectKey), &state.SessionCache{
		Host:           resolved.Host,
		ProjectKey:     resolved.ProjectKey,
		SessionID:      resolved.SessionID,
		RunKey:         resolved.RunKey,
		TranscriptPath: resolved.TranscriptPath,
		LastSeen:       time.Now().UTC(),
	}); err != nil {
		return fmt.Errorf("write claude session cache: %w", err)
	}
	return nil
}

func resolveHookRun(stdinPayload []byte, env *config.Env) (*config.Env, string, error) {
	if env == nil {
		env = config.Resolve()
	}
	resolved := *env
	if resolved.Host == "" {
		resolved.Host = "claude"
	}

	payload, err := decodeClaudePayload(stdinPayload)
	if err != nil {
		return nil, "", err
	}
	if payload.SessionID != "" {
		resolved.SessionID = payload.SessionID
	}
	if payload.TranscriptPath != "" || payload.Transcript != "" {
		resolved.TranscriptPath = firstNonEmpty(payload.TranscriptPath, payload.Transcript)
	}
	if payload.SessionID != "" {
		resolved.RunKey = payload.SessionID
	} else if resolved.RunKey == "" {
		resolved.RunKey = resolved.SessionID
	}
	if payload.CWD != "" {
		projectKey, err := host.ProjectKeyFromDir(payload.CWD)
		if err != nil {
			return nil, "", err
		}
		resolved.ProjectKey = projectKey
	}
	if resolved.RunKey == "" {
		return nil, "", fmt.Errorf("CERBERUS_RUN_KEY or Claude session_id is required")
	}

	adapter, err := host.NewFromEnv(&resolved)
	if err != nil {
		return nil, "", err
	}
	if resolved.ProjectKey == "" {
		projectKey, err := adapter.ProjectKey(&resolved)
		if err != nil {
			return nil, "", err
		}
		resolved.ProjectKey = projectKey
	}
	if resolved.StateRoot == "" {
		stateRoot, err := adapter.StateRoot(&resolved)
		if err != nil {
			return nil, "", err
		}
		resolved.StateRoot = stateRoot
	}
	return &resolved, state.RunDir(resolved.StateRoot, resolved.ProjectKey, resolved.RunKey), nil
}

func decodeClaudePayload(stdinPayload []byte) (claudePayload, error) {
	if len(stdinPayload) == 0 {
		return claudePayload{}, nil
	}
	var payload claudePayload
	if err := json.Unmarshal(stdinPayload, &payload); err != nil {
		return claudePayload{}, fmt.Errorf("parse claude hook payload: %w", err)
	}
	return payload, nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

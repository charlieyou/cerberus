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
	"github.com/charlieyou/cerberus/internal/telemetry"
)

type codexPayload struct {
	SessionID      string `json:"session_id"`
	TranscriptPath string `json:"transcript_path"`
	ProjectKey     string `json:"project_key"`
	Transcript     string `json:"transcript"`
	CWD            string `json:"cwd"`
	WorkspaceRoot  string `json:"workspace_root"`
	Prompt         string `json:"prompt"`
	StopReason     string `json:"stop_reason"`
}

func HandleCodexStop(stdinPayload []byte, env *config.Env) error {
	resolved, runRoot, err := resolveCodexHookRun(stdinPayload, env)
	if err != nil {
		return err
	}
	return writeCodexHookAllowed(runRoot, resolved)
}

func HandleCodexSessionStart(stdinPayload []byte, env *config.Env) error {
	return writeCodexSessionState(stdinPayload, env)
}

func HandleCodexPromptSubmit(stdinPayload []byte, env *config.Env) error {
	return writeCodexSessionState(stdinPayload, env)
}

func writeCodexSessionState(stdinPayload []byte, env *config.Env) error {
	resolved, runRoot, err := resolveCodexHookRun(stdinPayload, env)
	if err != nil {
		return err
	}
	if err := state.EnsureRunDir(runRoot); err != nil {
		return err
	}

	data, err := json.MarshalIndent(map[string]string{
		"run_key":          resolved.RunKey,
		"session_id":       resolved.SessionID,
		"codex_session_id": resolved.SessionID,
		"transcript_path":  resolved.TranscriptPath,
	}, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal codex session state: %w", err)
	}
	data = append(data, '\n')
	if err := os.WriteFile(filepath.Join(runRoot, "session.json"), data, 0o644); err != nil {
		return fmt.Errorf("write codex session state: %w", err)
	}
	return writeCodexHookAllowed(runRoot, resolved)
}

func resolveCodexHookRun(stdinPayload []byte, env *config.Env) (*config.Env, string, error) {
	if env == nil {
		env = config.Resolve()
	}
	resolved := *env
	if resolved.Host == "" {
		resolved.Host = "codex"
	}

	payload, err := decodeCodexPayload(stdinPayload)
	if err != nil {
		return nil, "", err
	}
	if payload.ProjectKey != "" {
		resolved.ProjectKey = payload.ProjectKey
	}
	if workspace := firstNonEmpty(payload.WorkspaceRoot, payload.CWD); workspace != "" {
		projectKey, err := host.ProjectKeyFromDir(workspace)
		if err != nil {
			return nil, "", err
		}
		resolved.ProjectKey = projectKey
	}

	adapter, err := host.NewFromEnv(&resolved)
	if err != nil {
		return nil, "", err
	}
	codexHost := host.NewCodexHost()
	sessionID, err := codexHost.ResolveSessionID(stdinPayload)
	if err != nil {
		return nil, "", err
	}
	resolved.SessionID = sessionID
	transcriptPath, err := codexHost.TranscriptPath(stdinPayload)
	if err != nil {
		return nil, "", err
	}
	resolved.TranscriptPath = transcriptPath
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
	if runKey, ok := activeCodexRunKey(&resolved, payload.SessionID); ok {
		resolved.RunKey = runKey
	} else if payload.SessionID != "" {
		resolved.RunKey = payload.SessionID
	} else if resolved.RunKey == "" {
		resolved.RunKey = resolved.SessionID
	}
	if resolved.RunKey == "" {
		return nil, "", fmt.Errorf("CERBERUS_RUN_KEY or Codex session_id is required")
	}
	return &resolved, state.RunDir(resolved.StateRoot, resolved.ProjectKey, resolved.RunKey), nil
}

func writeCodexHookAllowed(runRoot string, env *config.Env) error {
	return telemetry.WriteEvent(runRoot, telemetry.Event{
		Event:     telemetry.EventHookAllowed,
		Timestamp: time.Now().UTC(),
		Payload: map[string]any{
			"host":            "codex",
			"run_key":         env.RunKey,
			"session_id":      env.SessionID,
			"project_key":     env.ProjectKey,
			"transcript_path": env.TranscriptPath,
		},
	})
}

func activeCodexRunKey(env *config.Env, payloadSessionID string) (string, bool) {
	if env.StateRoot == "" || env.ProjectKey == "" {
		return "", false
	}
	if hasGateState(env.StateRoot, env.ProjectKey, env.RunKey) {
		return env.RunKey, true
	}
	if hasGateState(env.StateRoot, env.ProjectKey, payloadSessionID) {
		return payloadSessionID, true
	}
	return scanCodexProjectRunKey(env.StateRoot, env.ProjectKey)
}

func hasGateState(stateRoot, projectKey, runKey string) bool {
	if runKey == "" {
		return false
	}
	_, err := os.Stat(state.GateStatePath(state.RunDir(stateRoot, projectKey, runKey)))
	return err == nil
}

func scanCodexProjectRunKey(stateRoot, projectKey string) (string, bool) {
	pattern := filepath.Join(stateRoot, projectKey, "*", "gate-state.json")
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return "", false
	}

	for _, path := range matches {
		gate, err := state.ReadGateState(path)
		if err != nil {
			continue
		}
		runKey := filepath.Base(filepath.Dir(path))
		if gate.Status == state.StatusPending {
			return runKey, true
		}
	}
	return "", false
}

func decodeCodexPayload(stdinPayload []byte) (codexPayload, error) {
	if len(stdinPayload) == 0 {
		return codexPayload{}, nil
	}
	var payload codexPayload
	if err := json.Unmarshal(stdinPayload, &payload); err != nil {
		return codexPayload{}, fmt.Errorf("parse codex hook payload: %w", err)
	}
	return payload, nil
}

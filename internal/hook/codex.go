package hook

import (
	"encoding/json"
	"errors"
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
	_, err := handleCodexStopWithWait(stdinPayload, env, PollIntervalSeconds*time.Second, MaxWaitSeconds*time.Second)
	return err
}

func HandleCodexStopResponse(stdinPayload []byte, env *config.Env) (string, error) {
	return handleCodexStopWithWait(stdinPayload, env, PollIntervalSeconds*time.Second, MaxWaitSeconds*time.Second)
}

func handleCodexStopWithWait(stdinPayload []byte, env *config.Env, pollInterval, maxWait time.Duration) (string, error) {
	_, runRoot, err := resolveCodexHookRunWithPolicy(stdinPayload, env, activeCodexStopRunKey)
	if err != nil {
		return "", err
	}
	result, err := PollGateStateResult(state.GateStatePath(runRoot), pollInterval, maxWait)
	if err != nil {
		return "", err
	}
	return stopHookResponse(result)
}

func HandleCodexSessionStart(stdinPayload []byte, env *config.Env) error {
	return sessionInit(env, stdinPayload)
}

func HandleCodexPromptSubmit(stdinPayload []byte, env *config.Env) error {
	return sessionInit(env, stdinPayload)
}

func sessionInit(env *config.Env, stdinPayload []byte) error {
	resolved, runRoot, err := resolveCodexHookRun(stdinPayload, env)
	if err != nil {
		return err
	}
	if err := config.WriteCodexPluginRootCache(resolved.SessionID, resolved.Root); err != nil {
		return fmt.Errorf("write codex plugin root cache: %w", err)
	}
	if err := state.EnsureRunDir(runRoot); err != nil {
		return err
	}
	if err := state.WriteSessionCache(state.SessionCachePath(resolved.StateRoot, resolved.ProjectKey), &state.SessionCache{
		Host:           "codex",
		ProjectKey:     resolved.ProjectKey,
		SessionID:      resolved.SessionID,
		CodexSessionID: resolved.SessionID,
		RunKey:         resolved.RunKey,
		TranscriptPath: resolved.TranscriptPath,
		LastSeen:       time.Now().UTC(),
	}); err != nil {
		return fmt.Errorf("write codex session cache: %w", err)
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
	return resolveCodexHookRunWithPolicy(stdinPayload, env, activeCodexRunKey)
}

func resolveCodexHookRunWithPolicy(stdinPayload []byte, env *config.Env, runKeyPolicy func(*config.Env, string) (string, bool)) (*config.Env, string, error) {
	if env == nil {
		env = config.Resolve()
	}
	resolved := *env
	resolved.Host = "codex"

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
	if runKey, ok := runKeyPolicy(&resolved, payload.SessionID); ok {
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
	if env.StateRoot == "" || env.ProjectKey == "" || payloadSessionID == "" {
		return "", false
	}
	if matchSessionGate(env, env.RunKey, payloadSessionID) == sessionGateMatches {
		return env.RunKey, true
	}
	if matchSessionGate(env, payloadSessionID, payloadSessionID) == sessionGateMatches {
		return payloadSessionID, true
	}
	return cachedRunKeyForSession(env, payloadSessionID)
}

func activeCodexStopRunKey(env *config.Env, payloadSessionID string) (string, bool) {
	if env.StateRoot == "" || env.ProjectKey == "" || payloadSessionID == "" {
		return "", false
	}
	if matchSessionGate(env, env.RunKey, payloadSessionID) == sessionGateMatches {
		return env.RunKey, true
	}
	if matchSessionGate(env, payloadSessionID, payloadSessionID) == sessionGateMatches {
		return payloadSessionID, true
	}
	return cachedRunKeyForSession(env, payloadSessionID)
}

func hasGateState(stateRoot, projectKey, runKey string) bool {
	if runKey == "" {
		return false
	}
	_, err := os.Stat(state.GateStatePath(state.RunDir(stateRoot, projectKey, runKey)))
	return err == nil
}

type sessionGateMatch int

const (
	sessionGateMissing sessionGateMatch = iota
	sessionGateMatches
	sessionGateDifferent
	sessionGateUnreadable
)

func matchSessionGate(env *config.Env, runKey, sessionID string) sessionGateMatch {
	if runKey == "" || sessionID == "" {
		return sessionGateMissing
	}
	gate, err := state.ReadGateState(state.GateStatePath(state.RunDir(env.StateRoot, env.ProjectKey, runKey)))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return sessionGateMissing
		}
		if runKey == sessionID && hasGateState(env.StateRoot, env.ProjectKey, runKey) {
			return sessionGateMatches
		}
		return sessionGateUnreadable
	}
	if runKey == sessionID || gate.SessionID == sessionID {
		return sessionGateMatches
	}
	return sessionGateDifferent
}

func cachedRunKeyForSession(env *config.Env, sessionID string) (string, bool) {
	cache, err := state.ReadSessionCache(state.SessionCachePath(env.StateRoot, env.ProjectKey))
	if err != nil || cache.SessionID != sessionID || cache.RunKey == "" {
		return "", false
	}
	if matchSessionGate(env, cache.RunKey, sessionID) == sessionGateDifferent {
		return "", false
	}
	return cache.RunKey, true
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

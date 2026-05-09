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

type codexPayload struct {
	SessionID      string `json:"session_id"`
	TranscriptPath string `json:"transcript_path"`
	Transcript     string `json:"transcript"`
	CWD            string `json:"cwd"`
	WorkspaceRoot  string `json:"workspace_root"`
}

func HandleCodexStop(stdinPayload []byte, env *config.Env) error {
	_, runRoot, err := resolveCodexHookRun(stdinPayload, env)
	if err != nil {
		return err
	}
	return PollGateState(state.GateStatePath(runRoot), PollIntervalSeconds*time.Second, MaxWaitSeconds*time.Second)
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
	return nil
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
	if workspace := firstNonEmpty(payload.WorkspaceRoot, payload.CWD); workspace != "" {
		projectKey, err := host.ProjectKeyFromDir(workspace)
		if err != nil {
			return nil, "", err
		}
		resolved.ProjectKey = projectKey
	}
	if resolved.RunKey == "" {
		return nil, "", fmt.Errorf("CERBERUS_RUN_KEY or Codex session_id is required")
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

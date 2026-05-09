package host

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"github.com/charlieyou/cerberus/internal/config"
)

// Adapter resolves host-specific state paths behind a host-neutral interface.
type Adapter interface {
	Name() string
	StateRoot(env *config.Env) (string, error)
	ProjectKey(env *config.Env) (string, error)
}

type adapter struct {
	name string
}

// NewFromEnv selects the host adapter requested by CERBERUS_HOST.
func NewFromEnv(env *config.Env) (Adapter, error) {
	if env == nil {
		return nil, fmt.Errorf("host env is nil")
	}

	switch env.Host {
	case "claude", "codex", "generic":
		return adapter{name: env.Host}, nil
	default:
		return nil, fmt.Errorf("unsupported CERBERUS_HOST %q", env.Host)
	}
}

func (a adapter) Name() string {
	return a.name
}

func (a adapter) StateRoot(env *config.Env) (string, error) {
	if env == nil {
		return "", fmt.Errorf("host env is nil")
	}

	switch a.name {
	case "claude":
		return a.projectStateRoot(env, ".claude")
	case "codex":
		return a.projectStateRoot(env, ".codex")
	case "generic":
		if env.StateRoot == "" {
			return "", fmt.Errorf("CERBERUS_STATE_ROOT is required for generic host")
		}
		return env.StateRoot, nil
	default:
		return "", fmt.Errorf("unsupported host adapter %q", a.name)
	}
}

func (a adapter) ProjectKey(env *config.Env) (string, error) {
	if env == nil {
		return "", fmt.Errorf("host env is nil")
	}
	if env.Root == "" {
		return "", fmt.Errorf("CERBERUS_ROOT is required to derive project key")
	}

	absRoot, err := filepath.Abs(env.Root)
	if err != nil {
		return "", fmt.Errorf("resolve absolute CERBERUS_ROOT: %w", err)
	}

	sum := sha256.Sum256([]byte(absRoot))
	return hex.EncodeToString(sum[:])[:16], nil
}

func (a adapter) projectStateRoot(env *config.Env, hostDir string) (string, error) {
	projectKey, err := a.ProjectKey(env)
	if err != nil {
		return "", err
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve user home: %w", err)
	}

	return filepath.Join(home, hostDir, "projects", projectKey, "cerberus"), nil
}

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
	if env.ProjectKey != "" {
		return env.ProjectKey, nil
	}

	workingDirectory, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("resolve working directory: %w", err)
	}
	return ProjectKeyFromDir(workingDirectory)
}

// ProjectKeyFromDir derives the stable project key for an explicit host cwd.
func ProjectKeyFromDir(dir string) (string, error) {
	repoRoot, err := repoRootFromDir(dir)
	if err != nil {
		return "", err
	}

	sum := sha256.Sum256([]byte(repoRoot))
	return hex.EncodeToString(sum[:])[:16], nil
}

func repoRootFromDir(path string) (string, error) {
	dir, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolve absolute working directory %q: %w", path, err)
	}

	for {
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return dir, nil
		} else if err != nil && !os.IsNotExist(err) {
			return "", fmt.Errorf("inspect git root marker: %w", err)
		}

		parent := filepath.Dir(dir)
		if parent == dir {
			return filepath.Abs(path)
		}
		dir = parent
	}
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

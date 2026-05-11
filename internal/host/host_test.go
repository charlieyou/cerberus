package host

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"github.com/charlieyou/cerberus/internal/config"
)

func TestNewFromEnvSelectsKnownHosts(t *testing.T) {
	for _, name := range []string{"claude", "codex", "generic"} {
		t.Run(name, func(t *testing.T) {
			adapter, err := NewFromEnv(&config.Env{Host: name})
			if err != nil {
				t.Fatalf("NewFromEnv(%q) returned error: %v", name, err)
			}
			if adapter.Name() != name {
				t.Fatalf("Name() = %q, want %q", adapter.Name(), name)
			}
		})
	}
}

func TestNewFromEnvRejectsUnknownHost(t *testing.T) {
	if _, err := NewFromEnv(&config.Env{Host: "unknown"}); err == nil {
		t.Fatal("NewFromEnv(unknown) error = nil, want non-nil")
	}
}

func TestProjectKeyDerivesFromWorkspaceRoot(t *testing.T) {
	workspaceRoot := t.TempDir()
	if err := os.Mkdir(filepath.Join(workspaceRoot, ".git"), 0o755); err != nil {
		t.Fatalf("create git marker: %v", err)
	}
	nestedDir := filepath.Join(workspaceRoot, "pkg", "subpkg")
	if err := os.MkdirAll(nestedDir, 0o755); err != nil {
		t.Fatalf("create nested directory: %v", err)
	}

	oldWd, err := os.Getwd()
	if err != nil {
		t.Fatalf("os.Getwd() returned error: %v", err)
	}
	if err := os.Chdir(nestedDir); err != nil {
		t.Fatalf("os.Chdir() returned error: %v", err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(oldWd); err != nil {
			t.Fatalf("restore working directory: %v", err)
		}
	})

	env := &config.Env{Host: "claude", Root: filepath.Join(t.TempDir(), "plugin-root")}
	adapter, err := NewFromEnv(env)
	if err != nil {
		t.Fatalf("NewFromEnv() returned error: %v", err)
	}

	first, err := adapter.ProjectKey(env)
	if err != nil {
		t.Fatalf("ProjectKey() returned error: %v", err)
	}
	second, err := adapter.ProjectKey(env)
	if err != nil {
		t.Fatalf("ProjectKey() returned error on second call: %v", err)
	}

	currentRoot, err := os.Getwd()
	if err != nil {
		t.Fatalf("os.Getwd() returned error: %v", err)
	}
	repoRoot := filepath.Dir(filepath.Dir(currentRoot))
	sum := sha256.Sum256([]byte(repoRoot))
	want := hex.EncodeToString(sum[:])[:16]

	if first != want {
		t.Fatalf("ProjectKey() = %q, want %q", first, want)
	}
	if second != first {
		t.Fatalf("ProjectKey() second call = %q, want deterministic %q", second, first)
	}
}

func TestProjectKeyFromDirUsesExplicitWorkspaceRoot(t *testing.T) {
	workspaceRoot := t.TempDir()
	if err := os.Mkdir(filepath.Join(workspaceRoot, ".git"), 0o755); err != nil {
		t.Fatalf("create git marker: %v", err)
	}
	nestedDir := filepath.Join(workspaceRoot, "pkg", "subpkg")
	if err := os.MkdirAll(nestedDir, 0o755); err != nil {
		t.Fatalf("create nested directory: %v", err)
	}

	got, err := ProjectKeyFromDir(nestedDir)
	if err != nil {
		t.Fatalf("ProjectKeyFromDir() returned error: %v", err)
	}

	sum := sha256.Sum256([]byte(workspaceRoot))
	want := hex.EncodeToString(sum[:])[:16]
	if got != want {
		t.Fatalf("ProjectKeyFromDir() = %q, want %q", got, want)
	}
}

func TestProjectKeyUsesExplicitEnvValue(t *testing.T) {
	adapter, err := NewFromEnv(&config.Env{Host: "codex"})
	if err != nil {
		t.Fatalf("NewFromEnv() returned error: %v", err)
	}

	got, err := adapter.ProjectKey(&config.Env{ProjectKey: "explicit-key"})
	if err != nil {
		t.Fatalf("ProjectKey() returned error: %v", err)
	}
	if got != "explicit-key" {
		t.Fatalf("ProjectKey() = %q, want explicit-key", got)
	}
}

func TestStateRootForClaudeAndCodex(t *testing.T) {
	for _, tc := range []struct {
		host    string
		hostDir string
	}{
		{host: "claude", hostDir: ".claude"},
		{host: "codex", hostDir: ".codex"},
	} {
		t.Run(tc.host, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			t.Setenv("USERPROFILE", home)

			env := &config.Env{Host: tc.host, Root: t.TempDir()}
			adapter, err := NewFromEnv(env)
			if err != nil {
				t.Fatalf("NewFromEnv() returned error: %v", err)
			}
			key, err := adapter.ProjectKey(env)
			if err != nil {
				t.Fatalf("ProjectKey() returned error: %v", err)
			}

			got, err := adapter.StateRoot(env)
			if err != nil {
				t.Fatalf("StateRoot() returned error: %v", err)
			}
			want := filepath.Join(home, tc.hostDir, "projects", key, "cerberus")
			if got != want {
				t.Fatalf("StateRoot() = %q, want %q", got, want)
			}
		})
	}
}

func TestStateRootForGenericUsesEnvStateRoot(t *testing.T) {
	adapter, err := NewFromEnv(&config.Env{Host: "generic"})
	if err != nil {
		t.Fatalf("NewFromEnv() returned error: %v", err)
	}

	got, err := adapter.StateRoot(&config.Env{StateRoot: "/tmp/cerberus-state"})
	if err != nil {
		t.Fatalf("StateRoot() returned error: %v", err)
	}
	if got != "/tmp/cerberus-state" {
		t.Fatalf("StateRoot() = %q, want /tmp/cerberus-state", got)
	}
}

func TestStateRootForGenericRequiresEnvStateRoot(t *testing.T) {
	adapter, err := NewFromEnv(&config.Env{Host: "generic"})
	if err != nil {
		t.Fatalf("NewFromEnv() returned error: %v", err)
	}

	if _, err := adapter.StateRoot(&config.Env{}); err == nil {
		t.Fatal("StateRoot() error = nil, want non-nil")
	}
}

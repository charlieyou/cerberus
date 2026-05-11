package integration_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestPluginManifestsAdvertiseV2Version(t *testing.T) {
	repoRoot := manifestVersionsRepoRoot(t)
	for _, path := range []string{
		filepath.Join(repoRoot, ".claude-plugin", "plugin.json"),
		filepath.Join(repoRoot, ".codex-plugin", "plugin.json"),
	} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("ReadFile(%s) error = %v", path, err)
		}
		var manifest struct {
			Version string `json:"version"`
		}
		if err := json.Unmarshal(data, &manifest); err != nil {
			t.Fatalf("Unmarshal(%s) error = %v", path, err)
		}
		if manifest.Version != "2.0.1" {
			t.Fatalf("%s version = %q, want 2.0.1", path, manifest.Version)
		}
	}
}

func TestClaudeMarketplacePinsV2AndV1Rollback(t *testing.T) {
	repoRoot := manifestVersionsRepoRoot(t)
	path := filepath.Join(repoRoot, ".claude-plugin", "marketplace.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	var marketplace struct {
		Plugins []struct {
			Name    string          `json:"name"`
			Version string          `json:"version"`
			Source  json.RawMessage `json:"source"`
		} `json:"plugins"`
	}
	if err := json.Unmarshal(data, &marketplace); err != nil {
		t.Fatalf("Unmarshal(%s) error = %v", path, err)
	}

	var hasV2, hasV1Rollback bool
	for _, plugin := range marketplace.Plugins {
		if plugin.Name != "cerberus" {
			continue
		}
		if plugin.Version == "2.0.1" {
			hasV2 = true
		}
		if strings.HasPrefix(plugin.Version, "1.54.") {
			hasV1Rollback = true
			assertGitRollbackSource(t, path, plugin.Source)
		}
	}
	if !hasV2 {
		t.Fatalf("%s missing cerberus marketplace entry for version 2.0.1", path)
	}
	if !hasV1Rollback {
		t.Fatalf("%s missing cerberus marketplace rollback entry for version 1.54.x", path)
	}
}

func assertGitRollbackSource(t *testing.T, path string, sourceData json.RawMessage) {
	t.Helper()

	var source struct {
		Source string `json:"source"`
		URL    string `json:"url"`
		Ref    string `json:"ref"`
	}
	if err := json.Unmarshal(sourceData, &source); err != nil {
		t.Fatalf("%s v1 rollback source must be a git source object, got %s: %v", path, sourceData, err)
	}
	if source.Source != "url" {
		t.Fatalf("%s v1 rollback source.source = %q, want url", path, source.Source)
	}
	if source.URL != "https://github.com/charlieyou/cerberus.git" {
		t.Fatalf("%s v1 rollback source.url = %q, want https://github.com/charlieyou/cerberus.git", path, source.URL)
	}
	if !strings.HasPrefix(source.Ref, "v1.54.") {
		t.Fatalf("%s v1 rollback source.ref = %q, want v1.54.x tag", path, source.Ref)
	}
}

func manifestVersionsRepoRoot(t *testing.T) string {
	t.Helper()

	_, path, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(path), "..", ".."))
}

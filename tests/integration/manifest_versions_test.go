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
		if manifest.Version != "2.0.0" {
			t.Fatalf("%s version = %q, want 2.0.0", path, manifest.Version)
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
			Name    string `json:"name"`
			Version string `json:"version"`
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
		if plugin.Version == "2.0.0" {
			hasV2 = true
		}
		if strings.HasPrefix(plugin.Version, "1.54.") {
			hasV1Rollback = true
		}
	}
	if !hasV2 {
		t.Fatalf("%s missing cerberus marketplace entry for version 2.0.0", path)
	}
	if !hasV1Rollback {
		t.Fatalf("%s missing cerberus marketplace rollback entry for version 1.54.x", path)
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

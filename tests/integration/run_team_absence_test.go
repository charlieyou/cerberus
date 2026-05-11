package integration_test

import (
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestRunTeamCascadeAbsent(t *testing.T) {
	repoRoot := runTeamAbsenceRepoRoot(t)

	for _, rel := range []string{
		"skills/run-team",
		"agents/implementer.md",
		"templates/team-tasks-template.md",
		"templates/codex-hooks.json",
	} {
		path := filepath.Join(repoRoot, rel)
		if _, err := os.Stat(path); err == nil {
			t.Fatalf("%s exists, want absent", rel)
		} else if !os.IsNotExist(err) {
			t.Fatalf("Stat(%s) error = %v", rel, err)
		}
	}

	for _, root := range []string{"skills", "hooks", "agents", "templates", "prompts"} {
		assertNoRunTeamReferences(t, filepath.Join(repoRoot, root))
	}
}

func runTeamAbsenceRepoRoot(t *testing.T) string {
	t.Helper()

	_, path, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(path), "..", ".."))
}

func assertNoRunTeamReferences(t *testing.T, root string) {
	t.Helper()

	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if os.IsNotExist(err) {
				return filepath.SkipDir
			}
			return err
		}
		if d.IsDir() {
			return nil
		}

		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		text := string(data)
		for _, needle := range []string{
			"task-completed-hook",
			"teammate-idle-hook",
			"run-team",
			"implementer.md",
			"team-tasks-template",
		} {
			if strings.Contains(text, needle) {
				t.Fatalf("%s contains removed run-team reference %q", path, needle)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("WalkDir(%s) error = %v", root, err)
	}
}

// Package integration_test includes cleanup invariant tests that keep the v2
// plugin tree free of legacy shell entrypoints. These checks assert that bin/
// contains only the ignored Go build artifact, bin/ has no shell shebangs, the
// removed run-team hooks are not referenced, and every surviving skill invokes
// bin/cerberus instead of retired review-gate scripts.
package integration_test

import (
	"bytes"
	"errors"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

var shellShebangPattern = regexp.MustCompile(`^#![ \t]*(?:/bin/(?:sh|bash|dash|zsh)(?:[ \t].*)?|/usr/bin/env[ \t]+(?:sh|bash|dash|zsh)(?:[ \t].*)?)$`)

func TestCleanupInvariants(t *testing.T) {
	repoRoot := cleanupInvariantsRepoRoot(t)

	t.Run("bin contains only ignored cerberus artifact", func(t *testing.T) {
		assertBinContainsOnlyIgnoredCerberus(t, repoRoot)
	})

	t.Run("bin has no shell shebangs", func(t *testing.T) {
		for _, rel := range regularFilesUnder(t, repoRoot, "bin") {
			firstLine, err := firstLine(filepath.Join(repoRoot, rel))
			if err != nil {
				t.Fatalf("read first line of %s: %v", rel, err)
			}
			if shellShebangPattern.MatchString(firstLine) {
				t.Fatalf("%s has forbidden shell shebang %q", rel, firstLine)
			}
		}
	})

	t.Run("removed run-team hook references absent", func(t *testing.T) {
		for _, rel := range regularFilesUnder(t, repoRoot, "skills", "hooks", "agents", "bin") {
			data, err := os.ReadFile(filepath.Join(repoRoot, rel))
			if err != nil {
				t.Fatalf("ReadFile(%s) error = %v", rel, err)
			}
			text := string(data)
			for _, needle := range []string{"task-completed-hook", "teammate-idle-hook"} {
				if strings.Contains(text, needle) {
					t.Fatalf("%s contains removed run-team hook reference %q", rel, needle)
				}
			}
		}
	})

	t.Run("surviving skills reference cerberus binary only", func(t *testing.T) {
		skills := skillMarkdownFiles(t, repoRoot)
		if len(skills) != 13 {
			t.Fatalf("found %d surviving SKILL.md files, want 13: %v", len(skills), skills)
		}
		for _, rel := range skills {
			data, err := os.ReadFile(filepath.Join(repoRoot, rel))
			if err != nil {
				t.Fatalf("ReadFile(%s) error = %v", rel, err)
			}
			text := string(data)
			if !strings.Contains(text, "bin/cerberus") {
				t.Fatalf("%s must reference bin/cerberus", rel)
			}
			for _, forbidden := range []string{"bin/review-gate-models.sh", "bin/review-gate"} {
				if strings.Contains(text, forbidden) {
					t.Fatalf("%s contains retired binary reference %q", rel, forbidden)
				}
			}
		}
	})
}

func assertBinContainsOnlyIgnoredCerberus(t *testing.T, repoRoot string) {
	t.Helper()

	for _, rel := range regularFilesUnder(t, repoRoot, "bin") {
		if rel != "bin/cerberus" {
			t.Fatalf("bin contains disallowed file %s; only ignored bin/cerberus may exist", rel)
		}
	}

	tracked := gitLsFiles(t, repoRoot, "bin")
	for _, rel := range tracked {
		if rel != "bin/cerberus" {
			t.Fatalf("bin contains tracked disallowed file %s; only bin/cerberus is allowlisted", rel)
		}
	}

	if !gitignoreContainsLine(t, filepath.Join(repoRoot, ".gitignore"), "bin/cerberus") {
		t.Fatal(".gitignore must contain exact line bin/cerberus")
	}
	for _, rel := range tracked {
		if rel == "bin/cerberus" {
			t.Fatal("bin/cerberus is tracked; it must remain gitignored")
		}
	}
}

func cleanupInvariantsRepoRoot(t *testing.T) string {
	t.Helper()

	_, path, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(path), "..", ".."))
}

func regularFilesUnder(t *testing.T, repoRoot string, roots ...string) []string {
	t.Helper()

	var files []string
	for _, root := range roots {
		absRoot := filepath.Join(repoRoot, root)
		err := filepath.WalkDir(absRoot, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				if errors.Is(err, os.ErrNotExist) {
					return filepath.SkipDir
				}
				return err
			}
			if d.IsDir() {
				return nil
			}
			if !d.Type().IsRegular() {
				return nil
			}
			rel, err := filepath.Rel(repoRoot, path)
			if err != nil {
				return err
			}
			files = append(files, filepath.ToSlash(rel))
			return nil
		})
		if err != nil {
			t.Fatalf("WalkDir(%s) error = %v", root, err)
		}
	}
	return files
}

func skillMarkdownFiles(t *testing.T, repoRoot string) []string {
	t.Helper()

	var skills []string
	for _, rel := range regularFilesUnder(t, repoRoot, "skills") {
		if filepath.Base(rel) == "SKILL.md" {
			skills = append(skills, rel)
		}
	}
	return skills
}

func gitLsFiles(t *testing.T, repoRoot string, pathspec string) []string {
	t.Helper()

	cmd := exec.Command("git", "-C", repoRoot, "ls-files", pathspec)
	output, err := cmd.Output()
	if err != nil {
		t.Fatalf("git ls-files %s error = %v", pathspec, err)
	}
	output = bytes.TrimSpace(output)
	if len(output) == 0 {
		return nil
	}
	return strings.Split(string(output), "\n")
}

func gitignoreContainsLine(t *testing.T, path string, want string) bool {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == want {
			return true
		}
	}
	return false
}

func firstLine(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()

	buf := make([]byte, 256)
	n, err := file.Read(buf)
	if err != nil && err != io.EOF {
		return "", err
	}
	line := string(buf[:n])
	if idx := strings.IndexByte(line, '\n'); idx >= 0 {
		line = line[:idx]
	}
	if strings.HasSuffix(line, "\r") {
		line = strings.TrimSuffix(line, "\r")
	}
	return line, nil
}

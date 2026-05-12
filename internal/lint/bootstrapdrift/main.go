package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	startMarker = "# --- shared resolver (canonical body; identical across all callers) ---"
	endMarker   = "# --- shared resolver above; per-caller exec below (allowed to diverge) ---"
)

func main() {
	if err := run("."); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("bootstrap drift lint: ok")
}

func run(root string) error {
	canonical, err := canonicalBody(filepath.Join(root, "prompts", "host-neutral-bootstrap.md"))
	if err != nil {
		return err
	}
	var failures []string
	if err := filepath.WalkDir(filepath.Join(root, "skills"), func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", path, err))
			return nil
		}
		if entry.IsDir() || entry.Name() != "SKILL.md" {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		body, err := resolverRegionFromFile(path)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", filepath.ToSlash(rel), err))
			return nil
		}
		if body != canonical {
			failures = append(failures, firstDiff(filepath.ToSlash(rel), canonical, body))
		}
		return nil
	}); err != nil && !os.IsNotExist(err) {
		return err
	}
	for _, path := range []string{"hooks/hooks.json", "hooks/codex-hooks.json"} {
		for _, failure := range lintHookCommands(filepath.Join(root, path), path, canonical) {
			failures = append(failures, failure)
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf("bootstrap drift lint failed:\n%s", strings.Join(failures, "\n"))
	}
	return nil
}

func canonicalBody(path string) (string, error) {
	body, err := resolverRegionFromFile(path)
	if err != nil {
		return "", err
	}
	return body, nil
}

func resolverRegionFromFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return resolverRegion(string(data))
}

func resolverRegion(text string) (string, error) {
	start := strings.Index(text, startMarker)
	if start < 0 {
		return "", fmt.Errorf("missing resolver start marker")
	}
	afterStart := start + len(startMarker)
	end := strings.Index(text[afterStart:], endMarker)
	if end < 0 {
		return "", fmt.Errorf("missing resolver end marker")
	}
	body := text[afterStart : afterStart+end]
	return normalizeShell(body), nil
}

func lintHookCommands(path, displayPath, canonical string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return []string{fmt.Sprintf("%s: %v", displayPath, err)}
	}
	var manifest struct {
		Hooks map[string][]struct {
			Hooks []struct {
				Command string `json:"command"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return []string{fmt.Sprintf("%s: %v", displayPath, err)}
	}
	var failures []string
	for event, entries := range manifest.Hooks {
		for i, entry := range entries {
			for j, hook := range entry.Hooks {
				body, err := commandResolverBody(hook.Command)
				label := fmt.Sprintf("%s:%s[%d].hooks[%d].command", displayPath, event, i, j)
				if err != nil {
					failures = append(failures, fmt.Sprintf("%s: %v", label, err))
					continue
				}
				if body != canonical {
					failures = append(failures, firstDiff(label, canonical, body))
				}
			}
		}
	}
	return failures
}

func commandResolverBody(command string) (string, error) {
	idx := strings.Index(command, "exec \"$bin\" hook ")
	if idx < 0 {
		return "", fmt.Errorf("missing hook exec line")
	}
	prefix := strings.TrimSpace(command[:idx])
	prefix = strings.TrimPrefix(prefix, "sh -c '")
	body := strings.TrimSpace(prefix)
	return normalizeShell(body), nil
}

func normalizeShell(text string) string {
	text = strings.ReplaceAll(text, "\\\"", "\"")
	text = strings.ReplaceAll(text, "\\\\", "\\")
	text = strings.TrimSpace(text)
	text = strings.ReplaceAll(text, "\n", ";")
	parts := strings.Split(text, ";")
	var normalized []string
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if strings.HasPrefix(part, "then ") {
			normalized = append(normalized, "then")
			part = strings.TrimSpace(strings.TrimPrefix(part, "then "))
		}
		if strings.HasPrefix(part, "else ") {
			normalized = append(normalized, "else")
			part = strings.TrimSpace(strings.TrimPrefix(part, "else "))
		}
		normalized = append(normalized, part)
	}
	return strings.Join(nonEmpty(normalized), "\n")
}

func nonEmpty(values []string) []string {
	var out []string
	for _, value := range values {
		if value != "" {
			out = append(out, value)
		}
	}
	return out
}

func firstDiff(label, want, got string) string {
	wantLines := strings.Split(want, "\n")
	gotLines := strings.Split(got, "\n")
	limit := len(wantLines)
	if len(gotLines) < limit {
		limit = len(gotLines)
	}
	for i := 0; i < limit; i++ {
		if wantLines[i] != gotLines[i] {
			return fmt.Sprintf("%s: resolver drift at line %d: got %q, want %q", label, i+1, gotLines[i], wantLines[i])
		}
	}
	return fmt.Sprintf("%s: resolver drift: got %d lines, want %d", label, len(gotLines), len(wantLines))
}

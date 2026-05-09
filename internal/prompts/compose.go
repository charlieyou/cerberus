package prompts

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/charlieyou/cerberus/internal/roster"
)

const (
	reviewerPromptDir = "prompts/reviewers"
	strategyPromptDir = "prompts/strategies"
)

// Compose reads the on-disk persona, strategy, and reviewer prompt for a slot.
// The returned system prompt is persona -> strategy -> reviewer prompt joined
// with blank-line separators. User prompt composition is owned by callers.
func Compose(slot roster.RosterSlot, artifactType string) ([]byte, []byte, error) {
	root, err := rootDir()
	if err != nil {
		return nil, nil, err
	}
	return ComposeFromRoot(root, slot, artifactType)
}

// ComposeFromRoot is Compose with an explicit prompt root for tests and callers
// that already resolved CERBERUS_ROOT.
func ComposeFromRoot(root string, slot roster.RosterSlot, artifactType string) ([]byte, []byte, error) {
	if artifactType == "" {
		return nil, nil, fmt.Errorf("artifact type is required")
	}

	var parts [][]byte
	if slot.PersonaPath != "" {
		data, err := readPromptFile(resolvePath(root, slot.PersonaPath))
		if err != nil {
			return nil, nil, fmt.Errorf("read persona prompt %s: %w", slot.PersonaPath, err)
		}
		parts = append(parts, data)
	}

	if slot.Strategy != "" && slot.Strategy != "none" {
		path := filepath.Join(root, strategyPromptDir, slot.Strategy+".md")
		data, err := readPromptFile(path)
		if err != nil {
			return nil, nil, fmt.Errorf("read strategy prompt %s: %w", slot.Strategy, err)
		}
		parts = append(parts, data)
	}

	reviewerPath := filepath.Join(root, reviewerPromptDir, artifactType+".md")
	reviewerPrompt, err := readPromptFile(reviewerPath)
	if err != nil {
		return nil, nil, fmt.Errorf("read reviewer prompt %s: %w", artifactType, err)
	}
	parts = append(parts, reviewerPrompt)

	return bytes.Join(parts, []byte("\n\n")), nil, nil
}

func rootDir() (string, error) {
	if root := os.Getenv("CERBERUS_ROOT"); root != "" {
		return root, nil
	}
	if root := os.Getenv("CLAUDE_PLUGIN_ROOT"); root != "" {
		return root, nil
	}
	wd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("resolve current directory: %w", err)
	}
	return wd, nil
}

func resolvePath(root, path string) string {
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(root, path)
}

func readPromptFile(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return []byte(strings.TrimRight(string(data), "\n")), nil
}

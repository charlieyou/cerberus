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
// The returned system prompt is persona -> strategy joined with blank-line
// separators. The rendered reviewer prompt is returned as the user prompt so
// artifact content is delivered to reviewers via stdin.
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
	reviewerPrompt, err = renderReviewerTemplate(root, reviewerPrompt)
	if err != nil {
		return nil, nil, err
	}

	return bytes.Join(parts, []byte("\n\n")), reviewerPrompt, nil
}

func renderReviewerTemplate(root string, template []byte) ([]byte, error) {
	replacements := map[string]string{
		"CONTEXT":                firstEnv("REVIEW_GATE_CONTEXT", "REVIEW_GATE_AUTHOR_CONTEXT"),
		"DIFF_CONTENT":           os.Getenv("REVIEW_GATE_DIFF_CONTENT"),
		"PLAN_CONTENT":           os.Getenv("REVIEW_GATE_PLAN_CONTENT"),
		"SPEC_CONTENT":           os.Getenv("REVIEW_GATE_SPEC_CONTENT"),
		"ASK_CONTENT":            os.Getenv("REVIEW_GATE_ASK_CONTENT"),
		"EPIC_CONTEXT":           os.Getenv("REVIEW_GATE_EPIC_CONTEXT"),
		"PEER_BLOCK":             firstNonEmpty(os.Getenv("PEER_BLOCK"), PeerBroadcastMarker),
		"PRIOR_ROUND_SELF_BLOCK": os.Getenv("PRIOR_ROUND_SELF_BLOCK"),
		"STRATEGY_DIRECTIVE":     "",
	}
	if replacements["CONTEXT"] == "" {
		replacements["CONTEXT"] = "No additional context provided."
	}

	anchors, err := optionalStrategy(root, "confidence-anchors")
	if err != nil {
		return nil, err
	}
	replacements["CONFIDENCE_ANCHORS"] = anchors

	debateShape, err := optionalStrategy(root, "debate-output-shape")
	if err != nil {
		return nil, err
	}
	replacements["DEBATE_OUTPUT_SHAPE"] = debateShape

	rendered := string(template)
	for key, value := range replacements {
		rendered = strings.ReplaceAll(rendered, "${"+key+"}", value)
	}
	return []byte(rendered), nil
}

func optionalStrategy(root, name string) (string, error) {
	data, err := readPromptFile(filepath.Join(root, strategyPromptDir, name+".md"))
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("read strategy prompt %s: %w", name, err)
	}
	return string(data), nil
}

func firstEnv(names ...string) string {
	for _, name := range names {
		if value := os.Getenv(name); value != "" {
			return value
		}
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
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

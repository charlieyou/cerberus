package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/prompts"
	"github.com/charlieyou/cerberus/internal/reviewer"
	"github.com/charlieyou/cerberus/internal/roster"
)

var providers = []string{"claude", "codex", "gemini"}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	root, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("fixtures-refresh: resolve repo root: %w", err)
	}
	if err := requireProviderCLIs(); err != nil {
		return err
	}
	promptDir := filepath.Join(root, "tests", "fixtures", "_prompts")
	for _, provider := range providers {
		model, ok := config.DefaultModelForProvider(provider)
		if !ok {
			return fmt.Errorf("fixtures-refresh: no default model for %s", provider)
		}
		artifact, err := readProviderPrompt(promptDir, provider)
		if err != nil {
			return err
		}
		instanceID := provider + "#1"
		userPrompt, err := reviewerPrompt(root, provider, model, instanceID, artifact)
		if err != nil {
			return err
		}
		key := fixtureKey(userPrompt, instanceID)
		fixturePath := filepath.Join(root, "tests", "fixtures", provider, key+".json")
		if err := verifyMockLookupPath(provider, key, instanceID, fixturePath); err != nil {
			return err
		}
		response, err := (reviewer.Runner{Root: root}).Spawn(context.Background(), reviewer.Request{
			ID:       instanceID,
			Provider: provider,
			Model:    model,
			User:     userPrompt,
		})
		if err != nil {
			return fmt.Errorf("fixtures-refresh: %s with %s.txt: %w", provider, provider, err)
		}
		if err := os.MkdirAll(filepath.Dir(fixturePath), 0o755); err != nil {
			return fmt.Errorf("fixtures-refresh: create fixture dir: %w", err)
		}
		if err := os.WriteFile(fixturePath, response.Output, 0o644); err != nil {
			return fmt.Errorf("fixtures-refresh: write %s: %w", fixturePath, err)
		}
		fmt.Printf("wrote %s\n", fixturePath)
	}
	return nil
}

func requireProviderCLIs() error {
	for _, provider := range providers {
		if _, err := exec.LookPath(provider); err != nil {
			return fmt.Errorf("fixtures-refresh: missing required CLI: %s", provider)
		}
	}
	return nil
}

func readProviderPrompt(dir, provider string) ([]byte, error) {
	path := filepath.Join(dir, provider+".txt")
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("fixtures-refresh: read prompt %s: %w", path, err)
	}
	return body, nil
}

func reviewerPrompt(root, provider, model, instanceID string, artifact []byte) ([]byte, error) {
	_, user, err := prompts.ComposeFromRootWithReplacements(root, roster.RosterSlot{
		Provider:      provider,
		Model:         model,
		InstanceID:    instanceID,
		InstanceIndex: 1,
	}, "code", map[string]string{
		"CONTEXT":      "Fixture refresh smoke prompt. Return valid reviewer JSON for this small synthetic artifact.",
		"DIFF_CONTENT": string(artifact),
	})
	if err != nil {
		return nil, fmt.Errorf("fixtures-refresh: compose reviewer prompt for %s: %w", provider, err)
	}
	return user, nil
}

func fixtureKey(prompt []byte, instanceID string) string {
	sum := sha256.Sum256(prompt)
	return hex.EncodeToString(sum[:8]) + ":" + instanceID
}

func verifyMockLookupPath(provider, key, instanceID, fixturePath string) error {
	if !strings.HasSuffix(key, ":"+instanceID) {
		return fmt.Errorf("fixtures-refresh: key %q does not include instance ID %q", key, instanceID)
	}
	wantSuffix := filepath.Join("tests", "fixtures", provider, key+".json")
	if !strings.HasSuffix(fixturePath, wantSuffix) {
		return fmt.Errorf("fixtures-refresh: fixture path %s does not match mock lookup suffix %s", fixturePath, wantSuffix)
	}
	return nil
}

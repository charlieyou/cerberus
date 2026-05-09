package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/reviewer"
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
	prompts, err := readPrompts(filepath.Join(root, "tests", "fixtures", "_prompts"))
	if err != nil {
		return err
	}
	for _, provider := range providers {
		model, ok := config.DefaultModelForProvider(provider)
		if !ok {
			return fmt.Errorf("fixtures-refresh: no default model for %s", provider)
		}
		for _, prompt := range prompts {
			instanceID := provider + "#1"
			key := fixtureKey(prompt.body, instanceID)
			fixturePath := filepath.Join(root, "tests", "fixtures", provider, key+".json")
			if err := verifyMockLookupPath(provider, key, instanceID, fixturePath); err != nil {
				return err
			}
			response, err := (reviewer.Runner{Root: root}).Spawn(context.Background(), reviewer.Request{
				ID:       instanceID,
				Provider: provider,
				Model:    model,
				User:     prompt.body,
			})
			if err != nil {
				return fmt.Errorf("fixtures-refresh: %s with %s: %w", provider, prompt.name, err)
			}
			if err := os.MkdirAll(filepath.Dir(fixturePath), 0o755); err != nil {
				return fmt.Errorf("fixtures-refresh: create fixture dir: %w", err)
			}
			if err := os.WriteFile(fixturePath, response.Output, 0o644); err != nil {
				return fmt.Errorf("fixtures-refresh: write %s: %w", fixturePath, err)
			}
			fmt.Printf("wrote %s\n", fixturePath)
		}
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

type promptFile struct {
	name string
	body []byte
}

func readPrompts(dir string) ([]promptFile, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("fixtures-refresh: read prompt dir %s: %w", dir, err)
	}
	var names []string
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".txt" {
			continue
		}
		names = append(names, entry.Name())
	}
	sort.Strings(names)
	if len(names) == 0 {
		return nil, fmt.Errorf("fixtures-refresh: no .txt prompts in %s", dir)
	}
	prompts := make([]promptFile, 0, len(names))
	for _, name := range names {
		body, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, fmt.Errorf("fixtures-refresh: read prompt %s: %w", name, err)
		}
		prompts = append(prompts, promptFile{name: name, body: body})
	}
	return prompts, nil
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

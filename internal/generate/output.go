package generate

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

func WriteSuccess(outputDir, provider string, stdout []byte, rawJSON []byte) error {
	providerDir := filepath.Join(outputDir, provider)
	if err := os.MkdirAll(providerDir, 0o755); err != nil {
		return fmt.Errorf("create %s output directory: %w", provider, err)
	}
	if err := os.WriteFile(filepath.Join(providerDir, "draft.md"), stdout, 0o644); err != nil {
		return fmt.Errorf("write %s draft: %w", provider, err)
	}
	if len(rawJSON) > 0 {
		if err := os.WriteFile(filepath.Join(providerDir, "raw.json"), rawJSON, 0o644); err != nil {
			return fmt.Errorf("write %s raw JSON: %w", provider, err)
		}
	}
	return nil
}

func WriteFailure(outputDir, provider string, exitCode int, errMsg string) error {
	providerDir := filepath.Join(outputDir, provider)
	if err := os.MkdirAll(providerDir, 0o755); err != nil {
		return fmt.Errorf("create %s output directory: %w", provider, err)
	}
	if err := os.WriteFile(filepath.Join(outputDir, provider+".failed"), []byte(errMsg), 0o644); err != nil {
		return fmt.Errorf("write %s failure marker: %w", provider, err)
	}
	return nil
}

func WriteStats(outputDir, provider string, stats Stats) error {
	providerDir := filepath.Join(outputDir, provider)
	if err := os.MkdirAll(providerDir, 0o755); err != nil {
		return fmt.Errorf("create %s output directory: %w", provider, err)
	}
	data, err := json.MarshalIndent(stats, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal %s stats: %w", provider, err)
	}
	data = append(data, '\n')
	if err := os.WriteFile(filepath.Join(providerDir, "stats.json"), data, 0o644); err != nil {
		return fmt.Errorf("write %s stats: %w", provider, err)
	}
	return nil
}

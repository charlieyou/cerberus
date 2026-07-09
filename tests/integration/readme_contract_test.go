package integration_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadmeDocumentsImplementedCLIAndConfigSchema(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	data, err := os.ReadFile(filepath.Join(repoRoot, "README.md"))
	if err != nil {
		t.Fatalf("ReadFile(README.md) error = %v", err)
	}
	readme := string(data)

	for _, forbidden := range []string{
		"bin/cerberus clear-gate",
		"bin/cerberus generate --type",
		"persona_path:",
		"`persona_path`",
		"  consensus:",
		"    defaults:",
		"--roster",
		"--agents",
		"--reviewer",
		"--replace-slot",
	} {
		if strings.Contains(readme, forbidden) {
			t.Fatalf("README.md contains unimplemented CLI or roster schema %q", forbidden)
		}
	}

	for _, required := range []string{
		`bin/cerberus resolve --reason "manual clear"`,
		"bin/cerberus generate /tmp/create-plan-drafts",
		"  --type create-plan",
		"Cerberus sends the artifact or question prompt on stdin",
		"Ask-only flag",
		"export CERBERUS_HOST=generic",
		"  max_rounds: 3",
		"roster:",
		"    models:",
		"        effort: medium",
		"        persona: personas/security.md",
		"`consensus` remains a CLI flag",
		"Fix `persona` in `config.yaml`",
	} {
		if !strings.Contains(readme, required) {
			t.Fatalf("README.md missing implemented CLI or roster schema %q", required)
		}
	}

	codexData, err := os.ReadFile(filepath.Join(repoRoot, "docs", "CODEX.md"))
	if err != nil {
		t.Fatalf("ReadFile(docs/CODEX.md) error = %v", err)
	}
	codex := string(codexData)
	for _, forbidden := range []string{
		"README.md#roster-configuration",
		"README.md#review-code",
	} {
		if strings.Contains(codex, forbidden) {
			t.Fatalf("docs/CODEX.md contains stale README anchor %q", forbidden)
		}
	}
	for _, required := range []string{
		"README.md#configuration",
		"README.md#code-review",
		"$CERBERUS_ROOT/config/gemini-readonly-policy.toml",
	} {
		if !strings.Contains(codex, required) {
			t.Fatalf("docs/CODEX.md missing required doc string %q", required)
		}
	}
}

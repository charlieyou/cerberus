package integration_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadmeDocumentsImplementedCLIAndRosterSchema(t *testing.T) {
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
	} {
		if strings.Contains(readme, forbidden) {
			t.Fatalf("README.md contains unimplemented CLI or roster schema %q", forbidden)
		}
	}

	for _, required := range []string{
		`bin/cerberus resolve --reason "manual clear"`,
		"bin/cerberus generate /tmp/create-plan-drafts",
		"  --type create-plan",
		"  max_rounds: 3",
		"        persona: personas/security.md",
		"`consensus` is a CLI flag, not a roster YAML key",
		"Fix `persona` in the roster",
	} {
		if !strings.Contains(readme, required) {
			t.Fatalf("README.md missing implemented CLI or roster schema %q", required)
		}
	}
}

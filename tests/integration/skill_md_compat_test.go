package integration_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSkillMDGenerateInvocationsUseV2Binary(t *testing.T) {
	t.Skip("awaiting Epic F SKILL.md bootstrap update; unskip when skills call bin/cerberus generate")

	repoRoot := integrationRepoRoot(t)
	for _, skill := range []string{"create-spec", "create-plan", "healthcheck", "architecture-review"} {
		path := filepath.Join(repoRoot, "skills", skill, "SKILL.md")
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("ReadFile(%s) error = %v", path, err)
		}
		if !strings.Contains(string(data), "bin/cerberus generate") {
			t.Fatalf("%s must reference bin/cerberus generate", path)
		}
		if strings.Contains(string(data), "bin/generate") {
			t.Fatalf("%s still references v1 bin/generate", path)
		}
	}
}

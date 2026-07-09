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
	for _, skill := range []string{"create-spec", "create-plan"} {
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

func TestCreateSkillsPropagateExplicitModeWithoutOverridingConfigDefault(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	for _, skill := range []string{"create-spec", "create-plan"} {
		path := filepath.Join(repoRoot, "skills", skill, "SKILL.md")
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("ReadFile(%s) error = %v", path, err)
		}
		content := string(data)
		if strings.Contains(content, `${MODE:-smart}`) {
			t.Fatalf("%s forces smart mode instead of allowing defaults.mode", path)
		}
		for _, want := range []string{
			"Set `MODE` only when an explicit `--mode <name>` flag is present",
			"Modes only select a model panel from `config.yaml`",
			`MODE_ARGS=(--mode "$MODE")`,
			`ROUND_ARGS=(--max-rounds "$MAX_ROUNDS")`,
			`"${MODE_ARGS[@]}" --prompt-file`,
			`"${MODE_ARGS[@]}" "${ROUND_ARGS[@]}"`,
		} {
			if !strings.Contains(content, want) {
				t.Fatalf("%s missing mode propagation contract %q", path, want)
			}
		}
		for _, stale := range []string{
			"Round limits by mode",
			"Priority scope still follows the mode",
			"fast=P0/P1",
			"smart=P0",
			"In max mode",
		} {
			if strings.Contains(content, stale) {
				t.Fatalf("%s retains built-in-mode workflow policy %q", path, stale)
			}
		}
	}
}

func TestReviewPlanSkillUsesTrailingFocusText(t *testing.T) {
	path := filepath.Join(integrationRepoRoot(t), "skills", "review-plan", "SKILL.md")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	content := string(data)
	if strings.Contains(content, "--focus") {
		t.Fatalf("%s documents unsupported --focus flag", path)
	}
	if !strings.Contains(content, `spawn-plan-review plan.md "focus on error handling"`) {
		t.Fatalf("%s missing trailing focus example", path)
	}
}

func TestVerifyEpicSkillPlacesFlagsBeforeArtifact(t *testing.T) {
	path := filepath.Join(integrationRepoRoot(t), "skills", "verify-epic", "SKILL.md")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	content := string(data)
	if !strings.Contains(content, `spawn-epic-verify $ARGUMENTS -- "$EPIC_FILE"`) {
		t.Fatalf("%s must place verification flags before a delimited artifact", path)
	}
	for _, stale := range []string{
		`spawn-epic-verify specs/auth-epic.md --mode`,
		`spawn-epic-verify specs/feature.md --mode`,
		`spawn-epic-verify specs/refactor.md --consensus`,
	} {
		if strings.Contains(content, stale) {
			t.Fatalf("%s contains trailing flag example %q", path, stale)
		}
	}
}

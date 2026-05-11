package prompts

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/roster"
)

func TestComposeOrdersPersonaStrategyReviewerWithSeparators(t *testing.T) {
	root := t.TempDir()
	writePrompt(t, root, "personas/security.md", "persona")
	writePrompt(t, root, "prompts/strategies/falsification-first.md", "strategy")
	writePrompt(t, root, "prompts/reviewers/code.md", "reviewer")

	system, user, err := ComposeFromRoot(root, roster.RosterSlot{
		Strategy:    "falsification-first",
		PersonaPath: "personas/security.md",
	}, "code")
	if err != nil {
		t.Fatalf("ComposeFromRoot() error = %v", err)
	}
	if string(system) != "persona\n\nstrategy" {
		t.Fatalf("system prompt = %q, want persona/strategy order", system)
	}
	if string(user) != "reviewer" {
		t.Fatalf("user prompt = %q, want reviewer prompt", user)
	}
}

func TestComposeStrategyNoneSuppressesStrategy(t *testing.T) {
	root := t.TempDir()
	writePrompt(t, root, "personas/security.md", "persona")
	writePrompt(t, root, "prompts/strategies/none.md", "must not be read")
	writePrompt(t, root, "prompts/reviewers/spec.md", "reviewer")

	system, user, err := ComposeFromRoot(root, roster.RosterSlot{
		Strategy:    "none",
		PersonaPath: "personas/security.md",
	}, "spec")
	if err != nil {
		t.Fatalf("ComposeFromRoot() error = %v", err)
	}
	if string(system) != "persona" {
		t.Fatalf("system prompt = %q, want persona without strategy", system)
	}
	if string(user) != "reviewer" {
		t.Fatalf("user prompt = %q, want reviewer prompt", user)
	}
}

func TestComposeReadsEditedStrategyFromDisk(t *testing.T) {
	root := t.TempDir()
	strategyPath := filepath.Join("prompts", "strategies", "verification-first.md")
	writePrompt(t, root, strategyPath, "old strategy")
	writePrompt(t, root, "prompts/reviewers/plan.md", "reviewer")

	slot := roster.RosterSlot{Strategy: "verification-first"}
	system, user, err := ComposeFromRoot(root, slot, "plan")
	if err != nil {
		t.Fatalf("first ComposeFromRoot() error = %v", err)
	}
	if string(system) != "old strategy" {
		t.Fatalf("first system prompt = %q, want old strategy", system)
	}
	if string(user) != "reviewer" {
		t.Fatalf("first user prompt = %q, want reviewer prompt", user)
	}

	time.Sleep(time.Millisecond)
	writePrompt(t, root, strategyPath, "new strategy")
	system, user, err = ComposeFromRoot(root, slot, "plan")
	if err != nil {
		t.Fatalf("second ComposeFromRoot() error = %v", err)
	}
	if string(system) != "new strategy" {
		t.Fatalf("second system prompt = %q, want edited strategy", system)
	}
	if string(user) != "reviewer" {
		t.Fatalf("second user prompt = %q, want reviewer prompt", user)
	}
}

func TestComposeRendersReviewerTemplatePlaceholders(t *testing.T) {
	root := t.TempDir()
	writePrompt(t, root, "prompts/strategies/confidence-anchors.md", "anchors")
	writePrompt(t, root, "prompts/strategies/debate-output-shape.md", "shape")
	writePrompt(t, root, "prompts/reviewers/code.md", "A ${CONFIDENCE_ANCHORS}\nB ${CONTEXT}\nC ${DIFF_CONTENT}\nD ${DEBATE_OUTPUT_SHAPE}")
	t.Setenv("REVIEW_GATE_CONTEXT", "context body")
	t.Setenv("REVIEW_GATE_DIFF_CONTENT", "diff body")

	system, user, err := ComposeFromRoot(root, roster.RosterSlot{}, "code")
	if err != nil {
		t.Fatalf("ComposeFromRoot() error = %v", err)
	}
	if len(system) != 0 {
		t.Fatalf("system prompt = %q, want empty without persona or strategy", system)
	}
	want := "A anchors\nB context body\nC diff body\nD shape"
	if string(user) != want {
		t.Fatalf("user prompt = %q, want %q", user, want)
	}
}

func TestComposeKeepsLargeDiffOutOfSystemPrompt(t *testing.T) {
	root := t.TempDir()
	writePrompt(t, root, "personas/reviewer.md", "persona")
	writePrompt(t, root, "prompts/reviewers/code.md", "${DIFF_CONTENT}")
	t.Setenv("REVIEW_GATE_DIFF_CONTENT", strings.Repeat("x", 256*1024+1))

	system, user, err := ComposeFromRoot(root, roster.RosterSlot{PersonaPath: "personas/reviewer.md"}, "code")
	if err != nil {
		t.Fatalf("ComposeFromRoot() error = %v", err)
	}
	if string(system) != "persona" {
		t.Fatalf("system prompt = %q, want persona only", system)
	}
	if len(user) != 256*1024+1 {
		t.Fatalf("user prompt length = %d, want large diff in user prompt", len(user))
	}
}

func TestComposeGeneratorIncludesInterviewWhenEnabled(t *testing.T) {
	root := t.TempDir()
	writePrompt(t, root, "prompts/interview-engine.md", "interview engine")
	writePrompt(t, root, "prompts/generators/create-spec.md", "create spec generator")

	system, err := ComposeGeneratorWithOptionsFromRoot(root, "claude", "create-spec", "smart", false)
	if err != nil {
		t.Fatalf("ComposeGeneratorFromRoot() error = %v", err)
	}

	for _, want := range []string{"Cerberus generator type: create-spec.", "Cerberus generate mode: smart.", "Cerberus provider: claude.", "interview engine", "create spec generator"} {
		if !strings.Contains(system, want) {
			t.Fatalf("system prompt = %q, want %q", system, want)
		}
	}
}

func TestComposeGeneratorSkipInterviewChangesPrompt(t *testing.T) {
	root := t.TempDir()
	writePrompt(t, root, "prompts/interview-engine.md", "interview engine")
	writePrompt(t, root, "prompts/generators/create-plan.md", "create plan generator")

	withInterview, err := ComposeGeneratorWithOptionsFromRoot(root, "codex", "create-plan", "smart", false)
	if err != nil {
		t.Fatalf("ComposeGeneratorFromRoot(with interview) error = %v", err)
	}
	skipped, err := ComposeGeneratorWithOptionsFromRoot(root, "codex", "create-plan", "smart", true)
	if err != nil {
		t.Fatalf("ComposeGeneratorFromRoot(skip interview) error = %v", err)
	}

	if withInterview == skipped {
		t.Fatalf("skip-interview prompt matched interview prompt")
	}
	if strings.Contains(skipped, "interview engine") {
		t.Fatalf("skip-interview system prompt = %q, want no interview prompt", skipped)
	}
	if !strings.Contains(skipped, "create plan generator") {
		t.Fatalf("skip-interview system prompt = %q, want generator prompt", skipped)
	}
}

func TestComposeGeneratorHealthcheckDoesNotUseInterview(t *testing.T) {
	root := t.TempDir()
	writePrompt(t, root, "prompts/interview-engine.md", "interview engine")
	writePrompt(t, root, "prompts/generators/healthcheck.md", "healthcheck generator")

	system, err := ComposeGeneratorWithOptionsFromRoot(root, "gemini", "healthcheck", "max", false)
	if err != nil {
		t.Fatalf("ComposeGeneratorFromRoot() error = %v", err)
	}
	if strings.Contains(system, "interview engine") {
		t.Fatalf("healthcheck system prompt = %q, want no interview prompt", system)
	}
	if !strings.Contains(system, "Cerberus generate mode: max.") {
		t.Fatalf("healthcheck system prompt = %q, want mode", system)
	}
}

func writePrompt(t *testing.T, root, rel, content string) {
	t.Helper()
	path := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll(%q) error = %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content+"\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(%q) error = %v", path, err)
	}
}

package prompts

import (
	"os"
	"path/filepath"
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
	if string(system) != "persona\n\nstrategy\n\nreviewer" {
		t.Fatalf("system prompt = %q, want persona/strategy/reviewer order", system)
	}
	if user != nil {
		t.Fatalf("user prompt = %q, want nil", user)
	}
}

func TestComposeStrategyNoneSuppressesStrategy(t *testing.T) {
	root := t.TempDir()
	writePrompt(t, root, "personas/security.md", "persona")
	writePrompt(t, root, "prompts/strategies/none.md", "must not be read")
	writePrompt(t, root, "prompts/reviewers/spec.md", "reviewer")

	system, _, err := ComposeFromRoot(root, roster.RosterSlot{
		Strategy:    "none",
		PersonaPath: "personas/security.md",
	}, "spec")
	if err != nil {
		t.Fatalf("ComposeFromRoot() error = %v", err)
	}
	if string(system) != "persona\n\nreviewer" {
		t.Fatalf("system prompt = %q, want persona/reviewer without strategy", system)
	}
}

func TestComposeReadsEditedStrategyFromDisk(t *testing.T) {
	root := t.TempDir()
	strategyPath := filepath.Join("prompts", "strategies", "verification-first.md")
	writePrompt(t, root, strategyPath, "old strategy")
	writePrompt(t, root, "prompts/reviewers/plan.md", "reviewer")

	slot := roster.RosterSlot{Strategy: "verification-first"}
	system, _, err := ComposeFromRoot(root, slot, "plan")
	if err != nil {
		t.Fatalf("first ComposeFromRoot() error = %v", err)
	}
	if string(system) != "old strategy\n\nreviewer" {
		t.Fatalf("first system prompt = %q, want old strategy", system)
	}

	time.Sleep(time.Millisecond)
	writePrompt(t, root, strategyPath, "new strategy")
	system, _, err = ComposeFromRoot(root, slot, "plan")
	if err != nil {
		t.Fatalf("second ComposeFromRoot() error = %v", err)
	}
	if string(system) != "new strategy\n\nreviewer" {
		t.Fatalf("second system prompt = %q, want edited strategy", system)
	}
}

func TestComposeRendersReviewerTemplatePlaceholders(t *testing.T) {
	root := t.TempDir()
	writePrompt(t, root, "prompts/strategies/confidence-anchors.md", "anchors")
	writePrompt(t, root, "prompts/strategies/debate-output-shape.md", "shape")
	writePrompt(t, root, "prompts/reviewers/code.md", "A ${CONFIDENCE_ANCHORS}\nB ${CONTEXT}\nC ${DIFF_CONTENT}\nD ${DEBATE_OUTPUT_SHAPE}")
	t.Setenv("REVIEW_GATE_CONTEXT", "context body")
	t.Setenv("REVIEW_GATE_DIFF_CONTENT", "diff body")

	system, _, err := ComposeFromRoot(root, roster.RosterSlot{}, "code")
	if err != nil {
		t.Fatalf("ComposeFromRoot() error = %v", err)
	}
	want := "A anchors\nB context body\nC diff body\nD shape"
	if string(system) != want {
		t.Fatalf("system prompt = %q, want %q", system, want)
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

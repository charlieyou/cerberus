package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charlieyou/cerberus/internal/state"
)

func TestSpawnCodeReviewAgentsConsensusHappyPath(t *testing.T) {
	setSpawnTestEnv(t)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--consensus", "majority", "--agents", "claude,codex,gemini"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("spawn-code-review exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	gate := readSpawnGate(t)
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	if gate.RosterID != "agents" {
		t.Fatalf("gate roster_id = %q, want agents", gate.RosterID)
	}
}

func TestSpawnCodeReviewRejectsAgentsWithRoster(t *testing.T) {
	setSpawnTestEnv(t)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--agents", "claude,codex,gemini", "--roster", "default"}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("spawn-code-review exit code = 0, want non-zero")
	}
	if !strings.Contains(stderr.String(), "--agents is mutually exclusive with --roster and --reviewer") {
		t.Fatalf("stderr = %q, want --agents mutex error", stderr.String())
	}
}

func TestSpawnCodeReviewRejectsDebate(t *testing.T) {
	setSpawnTestEnv(t)
	var stdout, stderr bytes.Buffer

	code := run([]string{"spawn-code-review", "--debate"}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("spawn-code-review --debate exit code = 0, want non-zero")
	}
	if !strings.Contains(stderr.String(), "debate not yet implemented in Epic B; see Epic C") {
		t.Fatalf("stderr = %q, want debate error", stderr.String())
	}
}

func TestParseSpawnCodeReviewReviewerGrammarAndReplace(t *testing.T) {
	var stderr bytes.Buffer

	opts, err := parseSpawnCodeReviewFlags([]string{
		"--roster", "default",
		"--reviewer", "claude:opus",
		"--reviewer", "codex:gpt-5.3-codex:falsification-first",
		"--replace-slot", "claude#1",
		"--consensus", "all",
	}, &stderr)
	if err != nil {
		t.Fatalf("parseSpawnCodeReviewFlags() error = %v", err)
	}
	if opts.roster != "default" || opts.replaceSlot != "claude#1" || opts.consensus != "all" {
		t.Fatalf("parsed options = %#v, want roster/replace/consensus", opts)
	}
	if got, want := strings.Join(opts.reviewers, ","), "claude:opus,codex:gpt-5.3-codex:falsification-first"; got != want {
		t.Fatalf("reviewers = %q, want %q", got, want)
	}

	_, err = parseSpawnCodeReviewFlags([]string{"--reviewer", "claude:model:strategy:extra"}, &stderr)
	if err == nil || !strings.Contains(err.Error(), "--reviewer must use provider:model[:strategy]") {
		t.Fatalf("long reviewer parse error = %v, want grammar error", err)
	}
}

func TestResolveReviewersAppendsCLIReviewer(t *testing.T) {
	setRosterTestCWD(t)

	reviewers, rosterID, err := resolveReviewers(spawnCodeReviewOptions{
		roster:    "default",
		reviewers: []string{"claude:opus"},
	})
	if err != nil {
		t.Fatalf("resolveReviewers() error = %v", err)
	}
	if rosterID != "default" {
		t.Fatalf("rosterID = %q, want default", rosterID)
	}
	if got, want := len(reviewers), 2; got != want {
		t.Fatalf("len(reviewers) = %d, want %d", got, want)
	}
	if reviewers[0].ID != "codex#1" || reviewers[1].ID != "claude#1" {
		t.Fatalf("reviewer IDs = %#v, want codex#1 then claude#1", reviewers)
	}
}

func TestResolveReviewersReplacesSlot(t *testing.T) {
	setRosterTestCWD(t)

	reviewers, _, err := resolveReviewers(spawnCodeReviewOptions{
		roster:      "default",
		reviewers:   []string{"claude:opus"},
		replaceSlot: "codex#1",
	})
	if err != nil {
		t.Fatalf("resolveReviewers() error = %v", err)
	}
	if got, want := len(reviewers), 1; got != want {
		t.Fatalf("len(reviewers) = %d, want %d", got, want)
	}
	if reviewers[0].ID != "claude#1" || reviewers[0].Provider != "claude" || reviewers[0].Model != "opus" {
		t.Fatalf("reviewer = %#v, want claude#1 opus", reviewers[0])
	}
}

func setSpawnTestEnv(t *testing.T) {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("Abs(repo root) error = %v", err)
	}
	t.Setenv("PATH", filepath.Join(repoRoot, "tests", "mocks")+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CERBERUS_ROOT", repoRoot)
	t.Setenv("CERBERUS_HOST", "generic")
	t.Setenv("CERBERUS_STATE_ROOT", t.TempDir())
	t.Setenv("CERBERUS_PROJECT_KEY", "project")
	t.Setenv("CERBERUS_RUN_KEY", "run")
	t.Setenv("CERBERUS_MOCK_RECORD_DIR", t.TempDir())
}

func setRosterTestCWD(t *testing.T) {
	t.Helper()
	setSpawnTestEnv(t)
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".cerberus"), 0o755); err != nil {
		t.Fatalf("MkdirAll(.cerberus) error = %v", err)
	}
	rosters := []byte("version: 1\nrosters:\n  default:\n    reviewers:\n      - provider: codex\n        model: gpt\n")
	if err := os.WriteFile(filepath.Join(dir, ".cerberus", "rosters.yaml"), rosters, 0o644); err != nil {
		t.Fatalf("WriteFile(rosters.yaml) error = %v", err)
	}
	oldwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd() error = %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("Chdir(%s) error = %v", dir, err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(oldwd); err != nil {
			t.Fatalf("restore cwd %s: %v", oldwd, err)
		}
	})
}

func readSpawnGate(t *testing.T) *state.GateState {
	t.Helper()
	gate, err := state.ReadGateState(state.GateStatePath(state.RunDir(os.Getenv("CERBERUS_STATE_ROOT"), "project", "run")))
	if err != nil {
		t.Fatalf("ReadGateState() error = %v", err)
	}
	return gate
}

package integration_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/state"
)

func TestDebateMultiInstance(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	recordDir := t.TempDir()
	installMultiDebateMockCLI(t, repoRoot, recordDir)

	xdgConfigHome := t.TempDir()
	writeIntegrationFile(t, xdgConfigHome, "cerberus/rosters.yaml", `version: 1
rosters:
  debate-multi:
    reviewers:
      - provider: codex
        model: gpt-5.5
        strategy: verification-first
      - provider: codex
        model: gpt-5.4
        strategy: falsification-first
      - provider: codex
        model: gpt-5.3-codex
        strategy: decompose
      - provider: gemini
        model: gemini-3.1-pro
`)

	env := &config.Env{
		Host:       "generic",
		Root:       repoRoot,
		StateRoot:  t.TempDir(),
		ProjectKey: "integration-project",
		RunKey:     "debate-multi-instance",
	}

	binary := buildIntegrationCerberus(t, repoRoot)
	cmd := exec.Command(binary, "spawn-code-review", "--roster", "debate-multi", "--debate", "--max-rounds", "2", "multi-instance focus")
	cmd.Dir = repoRoot
	cmd.Env = append(os.Environ(),
		"CERBERUS_ROOT="+env.Root,
		"CERBERUS_HOST="+env.Host,
		"CERBERUS_STATE_ROOT="+env.StateRoot,
		"CERBERUS_PROJECT_KEY="+env.ProjectKey,
		"CERBERUS_RUN_KEY="+env.RunKey,
		"XDG_CONFIG_HOME="+xdgConfigHome,
	)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("spawn-code-review failed: %v\n%s", err, output)
	}

	slots := []orchestrator.ReviewerSlot{
		{ID: "codex#1", Provider: "codex", Model: "gpt-5.5", Strategy: "verification-first", InstanceIndex: 1},
		{ID: "codex#2", Provider: "codex", Model: "gpt-5.4", Strategy: "falsification-first", InstanceIndex: 2},
		{ID: "codex#3", Provider: "codex", Model: "gpt-5.3-codex", Strategy: "decompose", InstanceIndex: 3},
		{ID: "gemini#1", Provider: "gemini", Model: "gemini-3.1-pro", InstanceIndex: 1},
	}
	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	waitForResolvedGate(t, runRoot)
	assertResolvedGate(t, runRoot)
	assertReviewerDirs(t, runRoot, 1, 4)
	assertReviewerDirs(t, runRoot, 2, 4)
	assertNoProviderLeak(t, filepath.Join(runRoot, "iterations", "1", "round-2", "peer-broadcast.json"))
	assertPeerIDs(t, runRoot, map[string]string{
		"verifier":   "peer_1",
		"falsifier":  "peer_2",
		"decomposer": "peer_3",
		"policy":     "peer_4",
	})
	assertDistinctRoundTwoFindings(t, runRoot, slots)
	assertGeminiPolicyInReviewerStderr(t, runRoot, "gemini#1")
}

func TestDebateClaudeStrategiesProduceDivergentFindings(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	recordDir := t.TempDir()
	installMultiDebateMockCLI(t, repoRoot, recordDir)

	env := &config.Env{
		Host:       "generic",
		Root:       repoRoot,
		StateRoot:  t.TempDir(),
		ProjectKey: "integration-project",
		RunKey:     "debate-claude-strategies",
	}
	slots := []orchestrator.ReviewerSlot{
		{ID: "claude#1", Provider: "claude", Model: "claude-opus-4-7", Strategy: "verification-first", InstanceIndex: 1},
		{ID: "claude#2", Provider: "claude", Model: "claude-sonnet-4-5", Strategy: "falsification-first", InstanceIndex: 2},
	}

	verdict, err := (orchestrator.Orchestrator{
		Env: env,
	}).RunDebate(context.Background(), slots, []byte("Review same-provider strategy divergence."), 2)
	if err != nil {
		t.Fatalf("RunDebate() error = %v", err)
	}
	if verdict.Verdict != state.VerdictPass {
		t.Fatalf("verdict = %q, want pass", verdict.Verdict)
	}

	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	assertResolvedGate(t, runRoot)
	assertReviewerDirs(t, runRoot, 1, 2)
	assertReviewerDirs(t, runRoot, 2, 2)
	assertNoProviderLeak(t, filepath.Join(runRoot, "iterations", "1", "round-2", "peer-broadcast.json"))
	assertDistinctRoundTwoFindings(t, runRoot, slots)
}

func TestDebateCodexThreeInstancesSpawnDistinctIDs(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	recordDir := t.TempDir()
	installMultiDebateMockCLI(t, repoRoot, recordDir)

	env := &config.Env{
		Host:       "generic",
		Root:       repoRoot,
		StateRoot:  t.TempDir(),
		ProjectKey: "integration-project",
		RunKey:     "debate-codex-three",
	}
	slots := []orchestrator.ReviewerSlot{
		{ID: "codex#1", Provider: "codex", Model: "gpt-5.5", Strategy: "verification-first", InstanceIndex: 1},
		{ID: "codex#2", Provider: "codex", Model: "gpt-5.4", Strategy: "falsification-first", InstanceIndex: 2},
		{ID: "codex#3", Provider: "codex", Model: "gpt-5.3-codex", Strategy: "decompose", InstanceIndex: 3},
	}

	verdict, err := (orchestrator.Orchestrator{
		Env: env,
	}).RunDebate(context.Background(), slots, []byte("Review codex multi-instance roster."), 2)
	if err != nil {
		t.Fatalf("RunDebate() error = %v", err)
	}
	if verdict.Verdict != state.VerdictPass {
		t.Fatalf("verdict = %q, want pass", verdict.Verdict)
	}

	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
	assertResolvedGate(t, runRoot)
	assertReviewerDirs(t, runRoot, 1, 3)
	assertReviewerDirs(t, runRoot, 2, 3)
	assertRunTelemetryTotals(t, runRoot, 2)
	for _, reviewerID := range []string{"codex#1", "codex#2", "codex#3"} {
		if _, err := os.Stat(filepath.Join(runRoot, "iterations", "1", "round-1", "reviewers", reviewerID, "telemetry.json")); err != nil {
			t.Fatalf("%s telemetry missing: %v", reviewerID, err)
		}
	}
}

func waitForResolvedGate(t *testing.T, runRoot string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		gate, err := state.ReadGateState(state.GateStatePath(runRoot))
		if err == nil && gate.Status == state.StatusResolved {
			return
		}
		lastErr = err
		time.Sleep(25 * time.Millisecond)
	}
	if lastErr != nil {
		t.Fatalf("gate did not resolve within 5s: %v", lastErr)
	}
	t.Fatalf("gate did not resolve within 5s")
}

func assertResolvedGate(t *testing.T, runRoot string) {
	t.Helper()
	gate, err := state.ReadGateState(state.GateStatePath(runRoot))
	if err != nil {
		t.Fatalf("ReadGateState() error = %v", err)
	}
	if gate.Status != state.StatusResolved {
		t.Fatalf("gate status = %q, want resolved", gate.Status)
	}
	if gate.Verdict == nil || *gate.Verdict != state.VerdictPass {
		t.Fatalf("gate verdict = %v, want pass", gate.Verdict)
	}
}

func assertReviewerDirs(t *testing.T, runRoot string, round int, want int) {
	t.Helper()
	dir := filepath.Join(runRoot, "iterations", "1", fmt.Sprintf("round-%d", round), "reviewers")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir(%s) error = %v", dir, err)
	}
	if len(entries) != want {
		t.Fatalf("reviewer dirs in %s = %d, want %d", dir, len(entries), want)
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			t.Fatalf("%s is not a reviewer directory", filepath.Join(dir, entry.Name()))
		}
		data, err := os.ReadFile(filepath.Join(dir, entry.Name(), "telemetry.json"))
		if err != nil {
			t.Fatalf("ReadFile(%s telemetry) error = %v", entry.Name(), err)
		}
		var row struct {
			ReviewerID string `json:"reviewer_id"`
			Round      int    `json:"round"`
		}
		if err := json.Unmarshal(data, &row); err != nil {
			t.Fatalf("Unmarshal(%s telemetry) error = %v", entry.Name(), err)
		}
		if row.ReviewerID != entry.Name() {
			t.Fatalf("%s telemetry reviewer_id = %q, want %q", entry.Name(), row.ReviewerID, entry.Name())
		}
		if row.Round != round {
			t.Fatalf("%s telemetry round = %d, want %d", entry.Name(), row.Round, round)
		}
	}
}

func assertNoProviderLeak(t *testing.T, path string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	leakRe := regexp.MustCompile(`(?i)claude|codex|gemini|gpt-5\.5|gpt-5\.4|gpt-5\.3-codex|claude-opus|claude-sonnet|gemini-3\.1-pro`)
	if match := leakRe.Find(data); len(match) > 0 {
		t.Fatalf("%s leaked %q:\n%s", path, match, data)
	}
}

func assertPeerIDs(t *testing.T, runRoot string, wantByFindingMarker map[string]string) {
	t.Helper()
	records, err := state.ReadPeerBroadcast(runRoot, 1, 2)
	if err != nil {
		t.Fatalf("ReadPeerBroadcast() error = %v", err)
	}
	gotPeerIDs := make([]string, 0, len(records))
	for _, record := range records {
		gotPeerIDs = append(gotPeerIDs, record.PeerID)
	}
	sort.Strings(gotPeerIDs)
	wantPeerIDs := make([]string, 0, len(wantByFindingMarker))
	for _, peerID := range wantByFindingMarker {
		wantPeerIDs = append(wantPeerIDs, peerID)
	}
	sort.Strings(wantPeerIDs)
	if strings.Join(gotPeerIDs, ",") != strings.Join(wantPeerIDs, ",") {
		t.Fatalf("peer IDs = %v, want %v", gotPeerIDs, wantPeerIDs)
	}

	for marker, peerID := range wantByFindingMarker {
		found := false
		for _, record := range records {
			if len(record.Findings) == 0 || !strings.Contains(record.Findings[0].Title, marker) {
				continue
			}
			found = true
			if record.PeerID != peerID {
				t.Fatalf("record with marker %q peer_id = %q, want %q", marker, record.PeerID, peerID)
			}
		}
		if !found {
			t.Fatalf("no peer broadcast record contained finding marker %q", marker)
		}
	}
}

func assertDistinctRoundTwoFindings(t *testing.T, runRoot string, slots []orchestrator.ReviewerSlot) {
	t.Helper()
	titles := make(map[string]bool)
	for _, slot := range slots {
		data, err := os.ReadFile(filepath.Join(runRoot, "iterations", "1", "round-2", "reviewers", slot.ID, "output.json"))
		if err != nil {
			t.Fatalf("ReadFile(%s output) error = %v", slot.ID, err)
		}
		var output struct {
			Findings []struct {
				Title string `json:"title"`
			} `json:"findings"`
		}
		if err := json.Unmarshal(data, &output); err != nil {
			t.Fatalf("Unmarshal(%s output) error = %v", slot.ID, err)
		}
		if len(output.Findings) != 1 {
			t.Fatalf("%s findings = %d, want 1", slot.ID, len(output.Findings))
		}
		title := output.Findings[0].Title
		if titles[title] {
			t.Fatalf("duplicate finding title %q", title)
		}
		titles[title] = true
	}
	if len(titles) != len(slots) {
		t.Fatalf("distinct finding count = %d, want %d", len(titles), len(slots))
	}
}

func assertRunTelemetryTotals(t *testing.T, runRoot string, wantRounds int) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(runRoot, "run-telemetry.json"))
	if err != nil {
		t.Fatalf("ReadFile(run telemetry) error = %v", err)
	}
	var row struct {
		TotalRounds  int    `json:"total_rounds"`
		FinalVerdict string `json:"final_verdict"`
	}
	if err := json.Unmarshal(data, &row); err != nil {
		t.Fatalf("Unmarshal(run telemetry) error = %v", err)
	}
	if row.TotalRounds != wantRounds {
		t.Fatalf("total_rounds = %d, want %d", row.TotalRounds, wantRounds)
	}
	if row.FinalVerdict != state.VerdictPass {
		t.Fatalf("final_verdict = %q, want pass", row.FinalVerdict)
	}
}

func assertGeminiPolicyInReviewerStderr(t *testing.T, runRoot, instanceID string) {
	t.Helper()
	policyPath := filepath.Join(integrationRepoRoot(t), "config", "gemini-readonly-policy.toml")
	for _, round := range []int{1, 2} {
		path := filepath.Join(runRoot, "iterations", "1", fmt.Sprintf("round-%d", round), "reviewers", instanceID, "stderr.log")
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("ReadFile(%s) error = %v", path, err)
		}
		text := string(data)
		if !strings.Contains(text, "--policy-file") || !strings.Contains(text, policyPath) {
			t.Fatalf("%s = %q, want --policy-file %s", path, text, policyPath)
		}
	}
}

func installMultiDebateMockCLI(t *testing.T, repoRoot, recordDir string) {
	t.Helper()
	binDir := t.TempDir()
	script := `#!/bin/sh
set -eu
provider=$(basename "$0")
record_dir=${CERBERUS_DEBATE_MOCK_DIR:?}
fixture_dir=${CERBERUS_DEBATE_FIXTURE_DIR:?}
mkdir -p "$record_dir"
stdin_file=$(mktemp "$record_dir/stdin.XXXXXX")
cat > "$stdin_file"

model=""
previous=""
for arg in "$@"; do
  if [ "$previous" = "--model" ]; then
    model=$arg
  fi
  previous=$arg
done

round=1
if grep -q '"peer_id"' "$stdin_file"; then
  round=2
fi

while ! mkdir "$record_dir/lock" 2>/dev/null; do sleep 0.01; done
trap 'rmdir "$record_dir/lock"' EXIT
count_file="$record_dir/count"
if [ -f "$count_file" ]; then
  count=$(cat "$count_file")
else
  count=0
fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"
cp "$stdin_file" "$record_dir/invocation-$count.stdin"
printf '%s\n' "$provider" > "$record_dir/invocation-$count.provider"
printf '%s\n' "$@" > "$record_dir/invocation-$count.args"
printf 'mock %s argv: %s\n' "$provider" "$*" >&2
rm -f "$stdin_file"

case "$provider:$model" in
  claude:claude-opus-4-7) fixture="round-$round-claude1.json" ;;
  claude:claude-sonnet-4-5) fixture="round-$round-claude2.json" ;;
  codex:gpt-5.5) fixture="round-$round-codex1.json" ;;
  codex:gpt-5.4) fixture="round-$round-codex2.json" ;;
  codex:gpt-5.3-codex) fixture="round-$round-codex3.json" ;;
  gemini:gemini-3.1-pro) fixture="round-$round-gemini1.json" ;;
  *) echo "unexpected mock invocation provider=$provider model=$model" >&2; exit 1 ;;
esac
cat "$fixture_dir/$fixture"
`
	for _, provider := range []string{"claude", "codex", "gemini"} {
		path := filepath.Join(binDir, provider)
		if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
			t.Fatalf("WriteFile(mock %s) error = %v", provider, err)
		}
	}
	t.Setenv("CERBERUS_DEBATE_MOCK_DIR", recordDir)
	t.Setenv("CERBERUS_DEBATE_FIXTURE_DIR", filepath.Join(repoRoot, "tests", "fixtures", "debate-multi"))
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

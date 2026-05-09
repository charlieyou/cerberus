package integration_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/charlieyou/cerberus/internal/aggregate"
	"github.com/charlieyou/cerberus/internal/config"
	"github.com/charlieyou/cerberus/internal/orchestrator"
	"github.com/charlieyou/cerberus/internal/state"
)

func TestDebateMultiInstance(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	recordDir := t.TempDir()
	installMultiDebateMockCLI(t, repoRoot, recordDir)

	env := &config.Env{
		Host:       "generic",
		Root:       repoRoot,
		StateRoot:  t.TempDir(),
		ProjectKey: "integration-project",
		RunKey:     "debate-multi-instance",
	}

	slots := []orchestrator.ReviewerSlot{
		{ID: "codex#1", Provider: "codex", Model: "gpt-5.5", Strategy: "verification-first", InstanceIndex: 1},
		{ID: "codex#2", Provider: "codex", Model: "gpt-5.4", Strategy: "falsification-first", InstanceIndex: 2},
		{ID: "codex#3", Provider: "codex", Model: "gpt-5.3-codex", Strategy: "decompose", InstanceIndex: 3},
		{ID: "gemini#1", Provider: "gemini", Model: "gemini-3.1-pro", InstanceIndex: 1},
	}
	verdict, err := (orchestrator.Orchestrator{
		Env:       env,
		Consensus: aggregate.ModeMajority,
	}).RunDebate(context.Background(), slots, []byte("Review this multi-instance change."), 2)
	if err != nil {
		t.Fatalf("RunDebate() error = %v", err)
	}
	if verdict.Verdict != state.VerdictPass {
		t.Fatalf("verdict = %q, want pass", verdict.Verdict)
	}

	runRoot := state.RunDir(env.StateRoot, env.ProjectKey, env.RunKey)
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
	}
}

func assertNoProviderLeak(t *testing.T, path string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	leakRe := regexp.MustCompile(`(?i)claude|codex|gemini|gpt-5\.5|gpt-5\.4|gpt-5\.3-codex|claude-opus|gemini-3\.1-pro`)
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
	if len(titles) != 4 {
		t.Fatalf("distinct finding count = %d, want 4", len(titles))
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
  codex:gpt-5.5) fixture="round-$round-codex1.json" ;;
  codex:gpt-5.4) fixture="round-$round-codex2.json" ;;
  codex:gpt-5.3-codex) fixture="round-$round-codex3.json" ;;
  gemini:gemini-3.1-pro) fixture="round-$round-gemini1.json" ;;
  *) echo "unexpected mock invocation provider=$provider model=$model" >&2; exit 1 ;;
esac
cat "$fixture_dir/$fixture"
`
	for _, provider := range []string{"codex", "gemini"} {
		path := filepath.Join(binDir, provider)
		if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
			t.Fatalf("WriteFile(mock %s) error = %v", provider, err)
		}
	}
	t.Setenv("CERBERUS_DEBATE_MOCK_DIR", recordDir)
	t.Setenv("CERBERUS_DEBATE_FIXTURE_DIR", filepath.Join(repoRoot, "tests", "fixtures", "debate-multi"))
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

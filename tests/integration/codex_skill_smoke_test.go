package integration_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

var survivingCodexSkills = []string{
	"architecture-review",
	"ask",
	"clear-gate",
	"create-plan",
	"create-spec",
	"create-tasks",
	"healthcheck",
	"review-code",
	"review-plan",
	"review-spec",
	"review-tasks",
	"status",
	"verify-epic",
}

func TestCodexPluginSurfaceHasThirteenSurvivingSkills(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	data, err := os.ReadFile(filepath.Join(repoRoot, ".codex-plugin", "plugin.json"))
	if err != nil {
		t.Fatalf("ReadFile(.codex-plugin/plugin.json) error = %v", err)
	}
	var manifest struct {
		Skills string `json:"skills"`
		Hooks  string `json:"hooks"`
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("Unmarshal(.codex-plugin/plugin.json) error = %v", err)
	}
	if manifest.Skills != "./skills/" {
		t.Fatalf("codex manifest skills = %q, want ./skills/", manifest.Skills)
	}
	if manifest.Hooks != "./hooks/codex-hooks.json" {
		t.Fatalf("codex manifest hooks = %q, want ./hooks/codex-hooks.json", manifest.Hooks)
	}

	entries, err := os.ReadDir(filepath.Join(repoRoot, "skills"))
	if err != nil {
		t.Fatalf("ReadDir(skills) error = %v", err)
	}
	var got []string
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		if _, err := os.Stat(filepath.Join(repoRoot, "skills", entry.Name(), "SKILL.md")); err == nil {
			got = append(got, entry.Name())
		}
	}
	sort.Strings(got)
	want := append([]string(nil), survivingCodexSkills...)
	sort.Strings(want)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("codex skill dirs = %v, want exactly %v", got, want)
	}
}

func TestCodexSurvivingSkillRunBlocksSmoke(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	pluginRoot := newCodexSmokePluginRoot(t, repoRoot, binary)
	projectRoot := initIntegrationGitRepo(t)
	projectRoot = codexSmokeGitRoot(t, projectRoot)

	tests := map[string]struct {
		block       int
		wantExit    int
		wantOutput  string
		promptOnly  bool
		setupScript string
	}{
		"architecture-review": {block: 2, setupScript: `ARGUMENTS="--focus codex smoke"`},
		"ask":                 {block: 2, wantOutput: "ASK_RESULT=", setupScript: `ARGUMENTS="--agents codex codex smoke"`},
		"clear-gate":          {block: 2, wantExit: 1, wantOutput: "gate-state.json"},
		"create-plan":         {block: 4, setupScript: `printf 'codex smoke plan\n' > "$PROMPT_TMP"`},
		"create-spec":         {block: 4, setupScript: `printf 'codex smoke spec\n' > "$PROMPT_TMP"`},
		"create-tasks":        {promptOnly: true},
		"healthcheck":         {block: 2, setupScript: `ARGUMENTS="--focus codex smoke"`},
		"review-code":         {block: 2, setupScript: `ARGUMENTS="--agents codex codex smoke"`},
		"review-plan":         {block: 2, setupScript: `ARGUMENTS="--agents codex docs/codex-smoke-plan.md"`},
		"review-spec":         {block: 2, setupScript: `ARGUMENTS="--agents codex docs/codex-smoke-spec.md"`},
		"review-tasks":        {promptOnly: true},
		"status":              {block: 2, wantOutput: `"status":"no_active_gate"`},
		"verify-epic":         {block: 2, setupScript: `EPIC_FILE="$SMOKE_EPIC_FILE"; ARGUMENTS="--agents codex"`},
	}

	for _, skill := range survivingCodexSkills {
		t.Run(skill, func(t *testing.T) {
			tc, ok := tests[skill]
			if !ok {
				t.Fatalf("missing smoke case for %s", skill)
			}
			skillPath := filepath.Join(repoRoot, "skills", skill, "SKILL.md")
			if tc.promptOnly {
				for i, block := range bashBlocks(t, skillPath)[1:] {
					if strings.Contains(block, "bin/cerberus") {
						t.Fatalf("%s prompt-only block %d invokes backend: %s", skill, i+2, block)
					}
				}
				return
			}

			runBlock := bashBlock(t, skillPath, tc.block)
			script := strings.Join([]string{
				"set -euo pipefail",
				`ARGUMENTS="${ARGUMENTS:-}"`,
				`MODE="${MODE:-fast}"`,
				`MAX_ROUNDS="${MAX_ROUNDS:-0}"`,
				`PROMPT_TMP="${PROMPT_TMP:-$SMOKE_PROMPT_FILE}"`,
				`REVIEW_DIR="${REVIEW_DIR:-$SMOKE_REVIEW_DIR}"`,
				`TMPDIR="${TMPDIR:-$SMOKE_TMPDIR}"`,
				tc.setupScript,
				runBlock,
			}, "\n") + "\n"
			wantOutput := tc.wantOutput
			runCodexSmokeScript(t, binary, pluginRoot, projectRoot, skill, script, tc.wantExit, wantOutput)
		})
	}
}

func runCodexSmokeScript(t *testing.T, binary, pluginRoot, projectRoot, skill, script string, wantExit int, wantOutput string) {
	t.Helper()
	home := t.TempDir()
	sessionID := "codex-smoke-" + skill
	payload := map[string]string{
		"session_id":      sessionID,
		"transcript_path": filepath.Join(t.TempDir(), sessionID+".jsonl"),
		"cwd":             projectRoot,
		"workspace_root":  projectRoot,
	}
	payloadData, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("Marshal codex payload error = %v", err)
	}
	hook := exec.Command(binary, "hook", "codex-session-start")
	hook.Dir = projectRoot
	hook.Stdin = bytes.NewReader(payloadData)
	hook.Env = append(os.Environ(), "HOME="+home, "USERPROFILE="+home, "CERBERUS_HOST=codex")
	if output, err := hook.CombinedOutput(); err != nil {
		t.Fatalf("codex-session-start smoke failed: %v\n%s", err, output)
	}

	smokeDir := t.TempDir()
	promptFile := filepath.Join(smokeDir, "prompt.md")
	if err := os.WriteFile(promptFile, []byte("codex smoke prompt\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", promptFile, err)
	}
	epicFile := filepath.Join(smokeDir, "epic.md")
	if err := os.WriteFile(epicFile, []byte("# Codex Smoke Epic\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", epicFile, err)
	}
	docsDir := filepath.Join(projectRoot, "docs")
	if err := os.MkdirAll(docsDir, 0o755); err != nil {
		t.Fatalf("MkdirAll(%s) error = %v", docsDir, err)
	}
	for name, content := range map[string]string{
		"codex-smoke-plan.md": "# Codex Smoke Plan\n",
		"codex-smoke-spec.md": "# Codex Smoke Spec\n",
	} {
		path := filepath.Join(docsDir, name)
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatalf("WriteFile(%s) error = %v", path, err)
		}
	}
	reviewDir := filepath.Join(smokeDir, "review")
	if err := os.MkdirAll(reviewDir, 0o755); err != nil {
		t.Fatalf("MkdirAll(%s) error = %v", reviewDir, err)
	}

	scriptPath := filepath.Join(smokeDir, "smoke-"+skill+".bash")
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", scriptPath, err)
	}
	recordDir := filepath.Join(smokeDir, "records")
	cmd := exec.Command("bash", scriptPath)
	cmd.Dir = projectRoot
	cmd.Env = append(os.Environ(),
		"HOME="+home,
		"USERPROFILE="+home,
		"CERBERUS_ROOT="+pluginRoot,
		"CERBERUS_HOST=codex",
		"CERBERUS_MOCK_RECORD_DIR="+recordDir,
		"GOFLAGS=-modcacherw",
		"SMOKE_PROMPT_FILE="+promptFile,
		"SMOKE_EPIC_FILE="+epicFile,
		"SMOKE_REVIEW_DIR="+reviewDir,
		"SMOKE_TMPDIR="+smokeDir,
		"CLAUDE_PLUGIN_ROOT=",
		"CLAUDE_SKILL_DIR="+filepath.Join(pluginRoot, "skills", skill),
		"PATH="+integrationMockPath(t, integrationRepoRoot(t))+string(os.PathListSeparator)+os.Getenv("PATH"),
	)
	output, err := cmd.CombinedOutput()
	exitCode := 0
	if err != nil {
		exitErr, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("%s smoke command failed without exit status: %v\n%s", skill, err, output)
		}
		exitCode = exitErr.ExitCode()
	}
	if exitCode != wantExit {
		t.Fatalf("%s smoke exit = %d, want %d\n%s", skill, exitCode, wantExit, output)
	}
	if wantOutput != "" && !strings.Contains(string(output), wantOutput) {
		t.Fatalf("%s smoke output = %q, want substring %q", skill, output, wantOutput)
	}
}

func newCodexSmokePluginRoot(t *testing.T, repoRoot, binary string) string {
	t.Helper()
	_ = binary
	root := t.TempDir()
	if err := os.Symlink(filepath.Join(repoRoot, "prompts"), filepath.Join(root, "prompts")); err != nil {
		t.Fatalf("Symlink(prompts) error = %v", err)
	}
	if err := os.Symlink(filepath.Join(repoRoot, "skills"), filepath.Join(root, "skills")); err != nil {
		t.Fatalf("Symlink(skills) error = %v", err)
	}
	for _, rel := range []string{"Makefile", "cmd", "internal", "go.mod", "go.sum"} {
		if err := os.Symlink(filepath.Join(repoRoot, rel), filepath.Join(root, rel)); err != nil {
			t.Fatalf("Symlink(%s) error = %v", rel, err)
		}
	}
	binDir := filepath.Join(root, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("MkdirAll(%s) error = %v", binDir, err)
	}
	if err := os.Symlink(binary, filepath.Join(binDir, "cerberus")); err != nil {
		t.Fatalf("Symlink(bin/cerberus) error = %v", err)
	}
	for _, rel := range []string{"config/gemini-readonly-settings.json", "config/gemini-readonly-policy.toml"} {
		data, err := os.ReadFile(filepath.Join(repoRoot, rel))
		if err != nil {
			t.Fatalf("ReadFile(%s) error = %v", rel, err)
		}
		writeIntegrationFile(t, root, rel, string(data))
	}
	return root
}

func bashBlock(t *testing.T, path string, block int) string {
	t.Helper()
	blocks := bashBlocks(t, path)
	if block < 1 || block > len(blocks) {
		t.Fatalf("%s has %d bash blocks, cannot select block %d", path, len(blocks), block)
	}
	return blocks[block-1]
}

func bashBlocks(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	var blocks []string
	var current strings.Builder
	inBlock := false
	for _, line := range strings.Split(string(data), "\n") {
		switch {
		case !inBlock && line == "```bash":
			inBlock = true
			current.Reset()
		case inBlock && line == "```":
			inBlock = false
			blocks = append(blocks, current.String())
		case inBlock:
			current.WriteString(line)
			current.WriteByte('\n')
		}
	}
	if inBlock {
		t.Fatalf("%s bash block is not closed", path)
	}
	if len(blocks) == 0 {
		t.Fatalf("%s has no bash bootstrap block", path)
	}
	return blocks
}

func codexSmokeProjectKey(projectRoot string) string {
	sum := sha256.Sum256([]byte(projectRoot))
	return hex.EncodeToString(sum[:])[:16]
}

func codexSmokeGitRoot(t *testing.T, dir string) string {
	t.Helper()
	cmd := exec.Command("git", "-C", dir, "rev-parse", "--show-toplevel")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git rev-parse --show-toplevel failed: %v\n%s", err, output)
	}
	return strings.TrimSpace(string(output))
}

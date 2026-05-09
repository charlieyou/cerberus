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

func TestCodexSurvivingSkillBootstrapSmoke(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	pluginRoot := newCodexSmokePluginRoot(t, repoRoot, binary)
	projectRoot := initIntegrationGitRepo(t)
	projectRoot = codexSmokeGitRoot(t, projectRoot)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)

	payload := map[string]string{
		"session_id":      "codex-smoke-session",
		"transcript_path": filepath.Join(t.TempDir(), "codex-smoke.jsonl"),
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

	wantProjectKey := codexSmokeProjectKey(projectRoot)
	for _, skill := range survivingCodexSkills {
		t.Run(skill, func(t *testing.T) {
			bootstrap := firstBashBlock(t, filepath.Join(repoRoot, "skills", skill, "SKILL.md"))
			script := "set -euo pipefail\n" + bootstrap + "\nprintf '%s/%s/%s\\n' \"$CERBERUS_HOST\" \"$CERBERUS_PROJECT_KEY\" \"$CERBERUS_RUN_KEY\"\n"
			scriptPath := filepath.Join(t.TempDir(), "smoke-"+skill+".bash")
			if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
				t.Fatalf("WriteFile(%s) error = %v", scriptPath, err)
			}
			cmd := exec.Command("bash", scriptPath)
			cmd.Dir = projectRoot
			cmd.Env = append(os.Environ(),
				"HOME="+home,
				"USERPROFILE="+home,
				"CERBERUS_ROOT="+pluginRoot,
				"CERBERUS_HOST=codex",
				"CLAUDE_PLUGIN_ROOT=",
				"CLAUDE_SKILL_DIR="+filepath.Join(repoRoot, "skills", skill),
			)
			output, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("%s bootstrap failed: %v\n%s", skill, err, output)
			}
			want := "codex/" + wantProjectKey + "/codex-smoke-session"
			if strings.TrimSpace(string(output)) != want {
				t.Fatalf("%s bootstrap output = %q, want %q", skill, output, want)
			}
		})
	}
}

func newCodexSmokePluginRoot(t *testing.T, repoRoot, binary string) string {
	t.Helper()
	root := t.TempDir()
	for _, rel := range []string{
		"bin/cerberus-skill-env",
		"config/gemini-readonly-settings.json",
		"config/gemini-readonly-policy.toml",
	} {
		data, err := os.ReadFile(filepath.Join(repoRoot, rel))
		if err != nil {
			t.Fatalf("ReadFile(%s) error = %v", rel, err)
		}
		writeIntegrationFile(t, root, rel, string(data))
	}
	target := filepath.Join(root, "bin", "cerberus")
	data, err := os.ReadFile(binary)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", binary, err)
	}
	if err := os.WriteFile(target, data, 0o755); err != nil {
		t.Fatalf("WriteFile(%s) error = %v", target, err)
	}
	return root
}

func firstBashBlock(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	parts := strings.Split(string(data), "```bash\n")
	if len(parts) < 2 {
		t.Fatalf("%s has no bash bootstrap block", path)
	}
	block, _, ok := strings.Cut(parts[1], "\n```")
	if !ok {
		t.Fatalf("%s bash block is not closed", path)
	}
	return block
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

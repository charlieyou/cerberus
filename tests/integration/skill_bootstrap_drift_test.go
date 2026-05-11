package integration_test

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

const (
	resolverStartMarker = "# --- shared resolver (canonical body; identical across all callers) ---"
	resolverEndMarker   = "# --- shared resolver above; per-caller exec below (allowed to diverge) ---"
	skillExecLine       = `exec "$bin" "$@"`
)

var survivingSkillBootstraps = []string{
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

func TestSkillBootstrapDriftCanonicalParses(t *testing.T) {
	repoRoot := skillBootstrapDriftRepoRoot(t)
	path := filepath.Join(repoRoot, "prompts", "host-neutral-bootstrap.md")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}

	body, err := ExtractResolverBody(string(data))
	if err != nil {
		t.Fatalf("ExtractResolverBody(%s) error = %v", path, err)
	}
	if !strings.Contains(body, `bin="$root/bin/cerberus"`) {
		t.Fatalf("canonical resolver body must reference bin/cerberus")
	}
	if !strings.Contains(body, `export CERBERUS_ROOT="$root"`) {
		t.Fatalf("canonical resolver body must export the resolved root for the child process")
	}
	for _, want := range []string{
		`root="${CLAUDE_PLUGIN_ROOT}"`,
		`skill_dir="${CLAUDE_SKILL_DIR}"`,
		`claude_session="${CLAUDE_SESSION_ID}"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("canonical resolver body must use documented Claude Code substitution %q", want)
		}
	}
	if strings.Contains(body, `${CLAUDE_PLUGIN_ROOT:-`) {
		t.Fatalf("canonical resolver body must not hide CLAUDE_PLUGIN_ROOT inside shell-default expansion; Claude substitutes exact placeholders")
	}
	if !strings.Contains(string(data), `exec "$bin" "$@"`) {
		t.Fatalf("canonical bootstrap must document the skill exec form")
	}
	if !strings.Contains(string(data), `exec "$bin" hook <name>`) {
		t.Fatalf("canonical bootstrap must document the hook exec form")
	}
}

func TestSurvivingSkillBootstrapsMatchCanonicalResolver(t *testing.T) {
	repoRoot := skillBootstrapDriftRepoRoot(t)
	canonicalPath := filepath.Join(repoRoot, "prompts", "host-neutral-bootstrap.md")
	canonicalData, err := os.ReadFile(canonicalPath)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", canonicalPath, err)
	}

	canonicalBody, err := ExtractResolverBody(string(canonicalData))
	if err != nil {
		t.Fatalf("ExtractResolverBody(%s) error = %v", canonicalPath, err)
	}

	for _, skill := range survivingSkillBootstraps {
		t.Run(skill, func(t *testing.T) {
			path := filepath.Join(repoRoot, "skills", skill, "SKILL.md")
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("ReadFile(%s) error = %v", path, err)
			}
			content := string(data)

			body, err := ExtractResolverBody(content)
			if err != nil {
				t.Fatalf("ExtractResolverBody(%s) error = %v", path, err)
			}
			if body != canonicalBody {
				t.Fatalf("resolver body in %s drifted from %s", path, canonicalPath)
			}
			if !strings.Contains(content, resolverEndMarker+"\n"+skillExecLine) {
				t.Fatalf("%s must use skill exec line %q immediately after resolver", path, skillExecLine)
			}
			assertNoLegacySkillBootstrapReferences(t, path, content)
		})
	}
}

func TestStatusSkillRunBlockSupportsPluginRoot(t *testing.T) {
	repoRoot := skillBootstrapDriftRepoRoot(t)
	path := filepath.Join(repoRoot, "skills", "status", "SKILL.md")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}

	canonicalPath := filepath.Join(repoRoot, "prompts", "host-neutral-bootstrap.md")
	canonicalData, err := os.ReadFile(canonicalPath)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", canonicalPath, err)
	}
	canonicalBody, err := ExtractResolverBody(string(canonicalData))
	if err != nil {
		t.Fatalf("ExtractResolverBody(%s) error = %v", canonicalPath, err)
	}

	want := strings.TrimSuffix(canonicalBody, "\n") + "\n" + resolverEndMarker + "\n" + `exec "$bin" status --json $ARGUMENTS`
	if !strings.Contains(string(data), want) {
		t.Fatalf("%s status run block must use the lazy-build resolver and status exec line", path)
	}
}

func TestSkillCommandExamplesUsePluginRootFallback(t *testing.T) {
	repoRoot := skillBootstrapDriftRepoRoot(t)
	fallbackBin := "${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}/bin/cerberus"
	for _, skill := range survivingSkillBootstraps {
		t.Run(skill, func(t *testing.T) {
			path := filepath.Join(repoRoot, "skills", skill, "SKILL.md")
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("ReadFile(%s) error = %v", path, err)
			}
			content := string(data)
			for _, forbidden := range []string{
				"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT}}",
				"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}",
				"${CLAUDE_PLUGIN_ROOT:-",
				"$CERBERUS_ROOT/bin/cerberus",
				`make -C "$CERBERUS_ROOT"`,
			} {
				if strings.Contains(content, forbidden) {
					t.Fatalf("%s must use PLUGIN_ROOT fallback instead of %q", path, forbidden)
				}
			}
			for lineNumber, line := range strings.Split(content, "\n") {
				if strings.Contains(line, fallbackBin) {
					t.Fatalf("%s:%d must use the lazy-build resolver instead of invoking %s directly", path, lineNumber+1, fallbackBin)
				}
			}
		})
	}
}

func TestRevisionPromptsAuthorContextExportResolvedHostState(t *testing.T) {
	repoRoot := skillBootstrapDriftRepoRoot(t)
	paths, err := filepath.Glob(filepath.Join(repoRoot, "prompts", "revisions", "*.md"))
	if err != nil {
		t.Fatalf("Glob(revision prompts) error = %v", err)
	}
	if len(paths) == 0 {
		t.Fatal("no revision prompts found")
	}

	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("ReadFile(%s) error = %v", path, err)
			}
			content := string(data)
			if !strings.Contains(content, `"$bin" author-context`) {
				t.Fatalf("%s author-context snippet must invoke the resolved bin", path)
			}
			for _, want := range []string{
				`export CERBERUS_ROOT="$root"`,
				`export CERBERUS_HOST=claude CERBERUS_SESSION_ID=`,
				`export CERBERUS_HOST=codex CERBERUS_SESSION_ID=`,
				`claude_session="${CLAUDE_SESSION_ID}"`,
			} {
				if !strings.Contains(content, want) {
					t.Fatalf("%s author-context snippet must include %q", path, want)
				}
			}
			for _, forbidden := range []string{
				"${CLAUDE_PLUGIN_ROOT}/bin/cerberus author-context",
				"${CLAUDE_PLUGIN_ROOT:-",
			} {
				if strings.Contains(content, forbidden) {
					t.Fatalf("%s author-context snippet must not use %q", path, forbidden)
				}
			}
		})
	}
}

func TestReviewCodeCommandsExportResolvedRoot(t *testing.T) {
	repoRoot := skillBootstrapDriftRepoRoot(t)
	path := filepath.Join(repoRoot, "skills", "review-code", "SKILL.md")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}
	content := string(data)
	if strings.Contains(content, `"${CERBERUS_ROOT:-${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}}/bin/cerberus" spawn-code-review`) {
		t.Fatalf("%s must not invoke spawn-code-review through a fallback path without exporting the resolved root", path)
	}
	if got := strings.Count(content, `make -q -C "$root" build`); got < 6 {
		t.Fatalf("%s has %d review-code commands on the lazy-build path, want at least 6", path, got)
	}
	if got := strings.Count(content, `"$bin" spawn-code-review`); got != 6 {
		t.Fatalf("%s has %d review-code commands using resolved bin, want 6", path, got)
	}
}

func assertNoLegacySkillBootstrapReferences(t *testing.T, path, content string) {
	t.Helper()

	for _, forbidden := range []string{
		"bin/review-gate-models.sh",
		"bin/review-gate",
		"bin/cerberus-skill-env",
	} {
		if strings.Contains(content, forbidden) {
			t.Fatalf("%s must not reference legacy bootstrap path %q", path, forbidden)
		}
	}

	if regexp.MustCompile(`\bREVIEW_GATE_`).MatchString(content) {
		t.Fatalf("%s must not reference REVIEW_GATE_* aliases", path)
	}
}

func skillBootstrapDriftRepoRoot(t *testing.T) string {
	t.Helper()

	_, path, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(path), "..", ".."))
}

func ExtractResolverBody(input string) (string, error) {
	start := strings.Index(input, resolverStartMarker)
	if start < 0 {
		return "", errMissingResolverStart
	}

	bodyStart := start + len(resolverStartMarker)
	end := strings.Index(input[bodyStart:], resolverEndMarker)
	if end < 0 {
		return "", errMissingResolverEnd
	}

	body := input[start : bodyStart+end]
	if input[bodyStart:bodyStart+end] == "" {
		return "", errEmptyResolverBody
	}
	return body, nil
}

type resolverParseError string

func (e resolverParseError) Error() string {
	return string(e)
}

const (
	errMissingResolverStart resolverParseError = "missing shared resolver start marker"
	errMissingResolverEnd   resolverParseError = "missing shared resolver end marker"
	errEmptyResolverBody    resolverParseError = "empty shared resolver body"
)

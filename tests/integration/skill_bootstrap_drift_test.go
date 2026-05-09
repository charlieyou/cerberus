package integration_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	resolverStartMarker = "# --- shared resolver (canonical body; identical across all callers) ---"
	resolverEndMarker   = "# --- shared resolver above; per-caller exec below (allowed to diverge) ---"
)

func TestSkillBootstrapDriftCanonicalParses(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
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
	if !strings.Contains(string(data), `exec "$bin" "$@"`) {
		t.Fatalf("canonical bootstrap must document the skill exec form")
	}
	if !strings.Contains(string(data), `exec "$bin" hook <name>`) {
		t.Fatalf("canonical bootstrap must document the hook exec form")
	}
}

func ExtractResolverBody(input string) (string, error) {
	start := strings.Index(input, resolverStartMarker)
	if start < 0 {
		return "", errMissingResolverStart
	}

	end := strings.Index(input[start:], resolverEndMarker)
	if end < 0 {
		return "", errMissingResolverEnd
	}

	body := strings.TrimSpace(input[start : start+end])
	if body == "" {
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

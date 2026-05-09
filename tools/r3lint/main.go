package main

import (
	"fmt"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
)

const modulePath = "github.com/charlieyou/cerberus/"

func main() {
	if err := run("."); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(root string) error {
	var failures []string
	for _, path := range []string{
		"bin/review-gate-debate.sh",
	} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(path))); err == nil {
			failures = append(failures, fmt.Sprintf("%s: legacy shell debate runtime must not ship in the v2 source tree", path))
		} else if !os.IsNotExist(err) {
			failures = append(failures, fmt.Sprintf("%s: %v", path, err))
		}
	}

	for _, failure := range lintV2TextBoundaries(root) {
		failures = append(failures, failure)
	}

	if err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", path, err))
			return nil
		}
		if entry.IsDir() {
			switch entry.Name() {
			case ".git", ".beads":
				return filepath.SkipDir
			}
			return nil
		}
		if filepath.Ext(path) != ".go" {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", path, err))
			return nil
		}
		for _, failure := range lintGoFile(filepath.ToSlash(rel), path) {
			failures = append(failures, failure)
		}
		return nil
	}); err != nil {
		return err
	}

	if len(failures) > 0 {
		return fmt.Errorf("R3 structural lint failed:\n%s", strings.Join(failures, "\n"))
	}
	fmt.Println("R3 structural lint: ok")
	return nil
}

func lintGoFile(rel, path string) []string {
	file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
	if err != nil {
		return []string{fmt.Sprintf("%s: %v", rel, err)}
	}

	var failures []string
	for _, imported := range file.Imports {
		importPath := strings.Trim(imported.Path.Value, `"`)
		switch importPath {
		case modulePath + "internal/aggregate", modulePath + "internal/anonymize":
			if !allowedReviewCoreImport(rel) {
				failures = append(failures, fmt.Sprintf("%s: %s may only be imported by internal/orchestrator or tests", rel, importPath))
			}
		case modulePath + "internal/state":
			if !allowedStateImport(rel) {
				failures = append(failures, fmt.Sprintf("%s: %s may only be imported by approved state-I/O owners or tests", rel, importPath))
			}
		}
	}
	return failures
}

func lintV2TextBoundaries(root string) []string {
	var failures []string
	for _, dir := range []string{"bin", "cmd", "internal", "hooks", "skills", "prompts", "config", "templates"} {
		base := filepath.Join(root, dir)
		if _, err := os.Stat(base); os.IsNotExist(err) {
			continue
		}
		_ = filepath.WalkDir(base, func(path string, entry os.DirEntry, err error) error {
			if err != nil {
				failures = append(failures, fmt.Sprintf("%s: %v", path, err))
				return nil
			}
			if entry.IsDir() {
				if filepath.ToSlash(path) == filepath.ToSlash(filepath.Join(root, "bin", "tests")) {
					return filepath.SkipDir
				}
				return nil
			}
			rel, err := filepath.Rel(root, path)
			if err != nil {
				failures = append(failures, fmt.Sprintf("%s: %v", path, err))
				return nil
			}
			rel = filepath.ToSlash(rel)
			if strings.HasSuffix(rel, "_test.go") || strings.HasPrefix(rel, "internal/state/") {
				return nil
			}
			data, err := os.ReadFile(path)
			if err != nil {
				failures = append(failures, fmt.Sprintf("%s: %v", rel, err))
				return nil
			}
			for _, token := range []string{
				"debate_assign_peer_ids",
				"_rdc_aggregate_and_promote",
				"_rdc_write_gate_state_debate_block",
			} {
				if strings.Contains(string(data), token) {
					failures = append(failures, fmt.Sprintf("%s: legacy debate symbol %q duplicates internal Go ownership", rel, token))
				}
			}
			for _, token := range []string{
				"bin/review-gate",
				"review-gate-models.sh",
				"review-gate-lib.sh",
				"codex-session-init",
				"codex-stop-hook",
			} {
				if strings.Contains(string(data), token) {
					failures = append(failures, fmt.Sprintf("%s: legacy shipped entrypoint %q bypasses the v2 cerberus binary", rel, token))
				}
			}
			if strings.Contains(string(data), `"gate-state.json"`) {
				failures = append(failures, fmt.Sprintf("%s: direct gate-state.json literal outside internal/state bypasses state I/O ownership", rel))
			}
			if strings.HasPrefix(rel, "bin/") {
				for _, token := range []string{
					"/gate-state.json\"",
					"> \"$RUN_DIR/gate-state.json\"",
					"> \"$review_dir/gate-state.json\"",
					"> \"$state_file\"",
					"> \"$STATE_FILE\"",
					"mv \"$tmp_state\" \"$RUN_DIR/gate-state.json\"",
					"mv \"$tmp_state\" \"$review_dir/gate-state.json\"",
					"mv \"$tmp_state\" \"$state_file\"",
					"mv \"$tmp\" \"$STATE_FILE\"",
					"mv \"$TEMP_FILE\" \"$STATE_FILE\"",
				} {
					if strings.Contains(string(data), token) {
						failures = append(failures, fmt.Sprintf("%s: direct gate-state.json write pattern %q bypasses state I/O ownership", rel, token))
					}
				}
			}
			return nil
		})
	}
	return failures
}

func allowedReviewCoreImport(rel string) bool {
	if strings.HasPrefix(rel, "internal/orchestrator/") {
		return true
	}
	if strings.HasSuffix(rel, "_test.go") {
		return true
	}
	if strings.HasPrefix(rel, "tests/") {
		return true
	}
	return false
}

func allowedStateImport(rel string) bool {
	if strings.HasPrefix(rel, "internal/state/") {
		return true
	}
	if strings.HasSuffix(rel, "_test.go") || strings.HasPrefix(rel, "tests/") {
		return true
	}
	switch rel {
	case "internal/cli/author_context.go",
		"internal/cli/check.go",
		"internal/cli/cli.go",
		"internal/cli/resolve.go",
		"internal/cli/status.go",
		"internal/hook/claude.go",
		"internal/hook/codex.go",
		"internal/hook/poll.go",
		"internal/orchestrator/debate.go",
		"internal/orchestrator/orchestrator.go",
		"internal/reviewer/spawn.go",
		"internal/telemetry/telemetry.go":
		return true
	default:
		return false
	}
}

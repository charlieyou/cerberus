package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("plugin manifest version lint: ok")
}

func run() error {
	var failures []string
	for _, path := range []string{".claude-plugin/plugin.json", ".codex-plugin/plugin.json"} {
		data, err := os.ReadFile(path)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", path, err))
			continue
		}
		var manifest struct {
			Version string `json:"version"`
		}
		if err := json.Unmarshal(data, &manifest); err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", path, err))
			continue
		}
		if manifest.Version != "2.0.0" {
			failures = append(failures, fmt.Sprintf("%s: version = %q, want 2.0.0", path, manifest.Version))
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf("plugin manifest version lint failed:\n%s", strings.Join(failures, "\n"))
	}
	return nil
}

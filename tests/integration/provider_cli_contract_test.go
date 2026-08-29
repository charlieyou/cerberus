package integration

import (
	"os/exec"
	"strings"
	"testing"
)

func TestProviderCLIContractMatchesMocks(t *testing.T) {
	tests := []struct {
		name       string
		binary     string
		versionArg []string
		helpArgs   []string
		wantHelp   []string
		staleHelp  []string
	}{
		{
			name:       "claude",
			binary:     "claude",
			versionArg: []string{"--version"},
			helpArgs:   []string{"--help"},
			wantHelp:   []string{"--print", "--output-format", "--append-system-prompt", "--model", "--restricted", "--tools"},
		},
		{
			name:       "codex",
			binary:     "codex",
			versionArg: []string{"--version"},
			helpArgs:   []string{"exec", "--help"},
			wantHelp:   []string{"Usage: codex exec", "--json", "--model", "[PROMPT]"},
		},
		{
			name:       "gemini",
			binary:     "gemini",
			versionArg: []string{"--version"},
			helpArgs:   []string{"--help"},
			wantHelp:   []string{"--output-format", "--model", "--prompt", "--policy"},
			staleHelp:  []string{"--append-system-prompt", "--policy-file"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := exec.LookPath(tt.binary); err != nil {
				t.Skipf("%s not installed on PATH: %v", tt.binary, err)
			}

			versionOutput, err := exec.Command(tt.binary, tt.versionArg...).CombinedOutput()
			if err != nil {
				t.Fatalf("%s version command failed: %v\n%s", tt.binary, err, versionOutput)
			}
			t.Logf("%s version: %s", tt.binary, strings.TrimSpace(string(versionOutput)))

			helpOutput, err := exec.Command(tt.binary, tt.helpArgs...).CombinedOutput()
			if err != nil {
				t.Fatalf("%s help command failed: %v\n%s", tt.binary, err, helpOutput)
			}
			help := string(helpOutput)
			for _, want := range tt.wantHelp {
				if !strings.Contains(help, want) {
					t.Fatalf("%s help is missing %q\nhelp:\n%s", tt.binary, want, help)
				}
			}
			for _, stale := range tt.staleHelp {
				if strings.Contains(help, stale) {
					t.Fatalf("%s help still contains stale mock flag %q\nhelp:\n%s", tt.binary, stale, help)
				}
			}
		})
	}
}

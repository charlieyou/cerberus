package replay

import "testing"

func TestValidateInvocationAcceptsCerberusProviderArgs(t *testing.T) {
	tests := []struct {
		name     string
		provider string
		args     []string
	}{
		{
			name:     "claude reviewer",
			provider: "claude",
			args:     []string{"--print", "--output-format", "json", "--model", "claude-opus-4-7", "--append-system-prompt", "system"},
		},
		{
			name:     "claude generator",
			provider: "claude",
			args:     []string{"--print", "--output-format", "json", "--append-system-prompt", "system"},
		},
		{
			name:     "codex reviewer",
			provider: "codex",
			args:     []string{"exec", "--json", "--model", "gpt-5.5", "system"},
		},
		{
			name:     "gemini reviewer",
			provider: "gemini",
			args:     []string{"--output-format", "json", "--model", "gemini-3.1-pro-preview", "--prompt", "system", "--policy", "config/gemini-readonly-policy.toml"},
		},
		{
			name:     "direct mock smoke",
			provider: "codex",
			args:     nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := validateInvocation(tt.provider, tt.args); err != nil {
				t.Fatalf("validateInvocation() error = %v", err)
			}
		})
	}
}

func TestValidateInvocationRejectsStaleProviderArgs(t *testing.T) {
	tests := []struct {
		name     string
		provider string
		args     []string
	}{
		{
			name:     "codex root json flag",
			provider: "codex",
			args:     []string{"--json", "--model", "gpt-5.5", "--append-system-prompt", "system"},
		},
		{
			name:     "gemini removed json and policy-file flags",
			provider: "gemini",
			args:     []string{"--json", "--model", "gemini-3.1-pro-preview", "--append-system-prompt", "system", "--policy-file", "config/gemini-readonly-policy.toml"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := validateInvocation(tt.provider, tt.args); err == nil {
				t.Fatal("validateInvocation() error = nil, want stale argv rejection")
			}
		})
	}
}

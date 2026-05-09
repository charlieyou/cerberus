package config

import "testing"

func TestResolveReadsCerberusEnv(t *testing.T) {
	t.Setenv("CERBERUS_ROOT", "/plugin/root")
	t.Setenv("CERBERUS_HOST", "codex")
	t.Setenv("CERBERUS_RUN_KEY", "run-123")
	t.Setenv("CERBERUS_SESSION_ID", "session-456")
	t.Setenv("CERBERUS_STATE_ROOT", "/state/root")
	t.Setenv("CERBERUS_PROJECT_KEY", "project-key")
	t.Setenv("CERBERUS_TRANSCRIPT_PATH", "/tmp/transcript.jsonl")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "/fallback/root")

	env := Resolve()

	if env.Root != "/plugin/root" {
		t.Fatalf("Root = %q, want %q", env.Root, "/plugin/root")
	}
	if env.Host != "codex" {
		t.Fatalf("Host = %q, want %q", env.Host, "codex")
	}
	if env.RunKey != "run-123" {
		t.Fatalf("RunKey = %q, want %q", env.RunKey, "run-123")
	}
	if env.SessionID != "session-456" {
		t.Fatalf("SessionID = %q, want %q", env.SessionID, "session-456")
	}
	if env.StateRoot != "/state/root" {
		t.Fatalf("StateRoot = %q, want %q", env.StateRoot, "/state/root")
	}
	if env.ProjectKey != "project-key" {
		t.Fatalf("ProjectKey = %q, want %q", env.ProjectKey, "project-key")
	}
	if env.TranscriptPath != "/tmp/transcript.jsonl" {
		t.Fatalf("TranscriptPath = %q, want %q", env.TranscriptPath, "/tmp/transcript.jsonl")
	}
}

func TestResolveFallsBackToClaudePluginRootForRoot(t *testing.T) {
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "/claude/plugin")

	env := Resolve()

	if env.Root != "/claude/plugin" {
		t.Fatalf("Root = %q, want CLAUDE_PLUGIN_ROOT value", env.Root)
	}
}

func TestResolveLeavesUnsetCerberusValuesEmpty(t *testing.T) {
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("CERBERUS_RUN_KEY", "")
	t.Setenv("CERBERUS_SESSION_ID", "")
	t.Setenv("CERBERUS_STATE_ROOT", "")
	t.Setenv("CERBERUS_PROJECT_KEY", "")
	t.Setenv("CERBERUS_TRANSCRIPT_PATH", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")

	env := Resolve()

	if *env != (Env{}) {
		t.Fatalf("Resolve() = %+v, want zero Env", *env)
	}
}

func TestResolveDoesNotReadReviewGateRootAlias(t *testing.T) {
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
	t.Setenv("REVIEW_GATE_ROOT", "/review/gate")

	env := Resolve()

	if env.Root != "" {
		t.Fatalf("Root = %q, want empty", env.Root)
	}
}

func TestDefaultModelForProvider(t *testing.T) {
	tests := map[string]string{
		"claude": "claude-opus-4-7",
		"codex":  "gpt-5.5",
		"gemini": "gemini-3.1-pro",
	}
	for provider, want := range tests {
		got, ok := DefaultModelForProvider(provider)
		if !ok {
			t.Fatalf("DefaultModelForProvider(%q) ok = false, want true", provider)
		}
		if got != want {
			t.Fatalf("DefaultModelForProvider(%q) = %q, want %q", provider, got, want)
		}
	}

	if got, ok := DefaultModelForProvider("unknown"); ok || got != "" {
		t.Fatalf("DefaultModelForProvider(unknown) = %q/%v, want empty/false", got, ok)
	}
}

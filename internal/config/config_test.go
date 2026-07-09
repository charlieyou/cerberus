package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveReadsCerberusEnv(t *testing.T) {
	t.Setenv("CERBERUS_ROOT", "/plugin/root")
	t.Setenv("CERBERUS_HOST", "codex")
	t.Setenv("CERBERUS_RUN_KEY", "run-123")
	t.Setenv("CERBERUS_SESSION_ID", "session-456")
	t.Setenv("CERBERUS_STATE_ROOT", "/state/root")
	t.Setenv("CERBERUS_PROJECT_KEY", "project-key")
	t.Setenv("CERBERUS_TRANSCRIPT_PATH", "/tmp/transcript.jsonl")
	t.Setenv("PLUGIN_ROOT", "/fallback/root")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")

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
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "/claude/plugin")
	t.Setenv("CODEX_THREAD_ID", "")

	env := Resolve()

	if env.Root != "/claude/plugin" {
		t.Fatalf("Root = %q, want CLAUDE_PLUGIN_ROOT value", env.Root)
	}
	if env.Host != "claude" {
		t.Fatalf("Host = %q, want inferred claude host", env.Host)
	}
}

func TestResolveFallsBackToPluginRootAndInfersCodexHost(t *testing.T) {
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
	t.Setenv("PLUGIN_ROOT", "/codex/plugin")

	env := Resolve()

	if env.Root != "/codex/plugin" {
		t.Fatalf("Root = %q, want PLUGIN_ROOT value", env.Root)
	}
	if env.Host != "codex" {
		t.Fatalf("Host = %q, want inferred codex host", env.Host)
	}
}

func TestResolveWithBothPluginRootsInfersCodexHostAndUsesPluginRoot(t *testing.T) {
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "/claude/plugin")
	t.Setenv("PLUGIN_ROOT", "/codex/plugin")

	env := Resolve()

	if env.Root != "/codex/plugin" {
		t.Fatalf("Root = %q, want PLUGIN_ROOT value", env.Root)
	}
	if env.Host != "codex" {
		t.Fatalf("Host = %q, want inferred codex host", env.Host)
	}
}

func TestResolveNormalizesClaudeCodeHost(t *testing.T) {
	t.Setenv("CERBERUS_HOST", "claude-code")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "/claude/plugin")

	env := Resolve()

	if env.Host != "claude" {
		t.Fatalf("Host = %q, want claude", env.Host)
	}
	if env.Root != "/claude/plugin" {
		t.Fatalf("Root = %q, want claude plugin root", env.Root)
	}
}

func TestResolveInfersCodexHostAndSessionFromThreadID(t *testing.T) {
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("CERBERUS_SESSION_ID", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("CODEX_THREAD_ID", "codex-thread")

	env := Resolve()

	if env.Host != "codex" {
		t.Fatalf("Host = %q, want codex", env.Host)
	}
	if env.SessionID != "codex-thread" {
		t.Fatalf("SessionID = %q, want CODEX_THREAD_ID", env.SessionID)
	}
}

func TestResolveCodexSignalsOverrideLeakedCerberusHost(t *testing.T) {
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "claude")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "/wrong/claude/plugin")
	t.Setenv("PLUGIN_ROOT", "/codex/plugin")
	t.Setenv("CODEX_THREAD_ID", "")

	env := Resolve()

	if env.Host != "codex" {
		t.Fatalf("Host = %q, want codex", env.Host)
	}
	if env.Root != "/codex/plugin" {
		t.Fatalf("Root = %q, want PLUGIN_ROOT value", env.Root)
	}
}

func TestResolveCodexThreadOverridesLeakedCerberusSession(t *testing.T) {
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "claude")
	t.Setenv("CERBERUS_SESSION_ID", "claude-session")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "/wrong/claude/plugin")
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("CODEX_THREAD_ID", "codex-thread")

	env := Resolve()

	if env.Host != "codex" {
		t.Fatalf("Host = %q, want codex", env.Host)
	}
	if env.SessionID != "codex-thread" {
		t.Fatalf("SessionID = %q, want CODEX_THREAD_ID", env.SessionID)
	}
}

func TestResolveReadsCodexPluginRootCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("CODEX_THREAD_ID", "codex-thread")
	if err := WriteCodexPluginRootCache("codex-thread", "/cached/plugin"); err != nil {
		t.Fatalf("WriteCodexPluginRootCache() error = %v", err)
	}

	env := Resolve()

	if env.Root != "/cached/plugin" {
		t.Fatalf("Root = %q, want cached plugin root", env.Root)
	}
}

func TestResolveCodexUsesCacheInsteadOfLeakedClaudePluginRoot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "/wrong/claude/plugin")
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("CODEX_THREAD_ID", "codex-thread")
	if err := WriteCodexPluginRootCache("codex-thread", "/cached/plugin"); err != nil {
		t.Fatalf("WriteCodexPluginRootCache() error = %v", err)
	}

	env := Resolve()

	if env.Host != "codex" {
		t.Fatalf("Host = %q, want codex", env.Host)
	}
	if env.Root != "/cached/plugin" {
		t.Fatalf("Root = %q, want cached plugin root", env.Root)
	}
}

func TestResolveCodexDoesNotUseLeakedClaudePluginRootWithoutCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CERBERUS_HOST", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "/wrong/claude/plugin")
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("CODEX_THREAD_ID", "codex-thread")

	env := Resolve()

	if env.Host != "codex" {
		t.Fatalf("Host = %q, want codex", env.Host)
	}
	if env.Root != "" {
		t.Fatalf("Root = %q, want empty without PLUGIN_ROOT or cache", env.Root)
	}
}

func TestCodexPluginRootCachePath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)

	path, err := CodexPluginRootCachePath("session-id")
	if err != nil {
		t.Fatalf("CodexPluginRootCachePath() error = %v", err)
	}
	want := filepath.Join(home, ".codex", "cerberus", "sessions", "session-id", "plugin-root")
	if path != want {
		t.Fatalf("CodexPluginRootCachePath() = %q, want %q", path, want)
	}
	if err := WriteCodexPluginRootCache("session-id", "/plugin/root"); err != nil {
		t.Fatalf("WriteCodexPluginRootCache() error = %v", err)
	}
	data, err := os.ReadFile(want)
	if err != nil {
		t.Fatalf("ReadFile(cache) error = %v", err)
	}
	if string(data) != "/plugin/root\n" {
		t.Fatalf("cache contents = %q, want plugin root", data)
	}
}

func TestCodexPluginRootCachePathUsesUserProfileWhenHomeUnset(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", "")
	t.Setenv("USERPROFILE", home)

	path, err := CodexPluginRootCachePath("session-id")
	if err != nil {
		t.Fatalf("CodexPluginRootCachePath() error = %v", err)
	}
	want := filepath.Join(home, ".codex", "cerberus", "sessions", "session-id", "plugin-root")
	if path != want {
		t.Fatalf("CodexPluginRootCachePath() = %q, want %q", path, want)
	}
}

func TestResolveUsesExplicitHostWhenNoHostSignalsExist(t *testing.T) {
	t.Setenv("CERBERUS_HOST", "generic")
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("CLAUDE_SESSION_ID", "")
	t.Setenv("CLAUDE_SKILL_DIR", "")

	env := Resolve()

	if env.Host != "generic" {
		t.Fatalf("Host = %q, want explicit CERBERUS_HOST fallback", env.Host)
	}
}

func TestResolveFallsBackToReviewGateSessionKey(t *testing.T) {
	t.Setenv("CERBERUS_RUN_KEY", "")
	t.Setenv("REVIEW_GATE_SESSION_KEY", "legacy-run-key")

	env := Resolve()

	if env.RunKey != "legacy-run-key" {
		t.Fatalf("RunKey = %q, want REVIEW_GATE_SESSION_KEY value", env.RunKey)
	}
}

func TestResolvePrefersCerberusRunKey(t *testing.T) {
	t.Setenv("CERBERUS_RUN_KEY", "cerberus-run-key")
	t.Setenv("REVIEW_GATE_SESSION_KEY", "legacy-run-key")

	env := Resolve()

	if env.RunKey != "cerberus-run-key" {
		t.Fatalf("RunKey = %q, want CERBERUS_RUN_KEY value", env.RunKey)
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
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("CLAUDE_SESSION_ID", "")

	env := Resolve()

	if *env != (Env{}) {
		t.Fatalf("Resolve() = %+v, want zero Env", *env)
	}
}

func TestResolveDoesNotReadReviewGateRootAlias(t *testing.T) {
	t.Setenv("CERBERUS_ROOT", "")
	t.Setenv("CLAUDE_PLUGIN_ROOT", "")
	t.Setenv("PLUGIN_ROOT", "")
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("CLAUDE_SESSION_ID", "")
	t.Setenv("REVIEW_GATE_ROOT", "/review/gate")

	env := Resolve()

	if env.Root != "" {
		t.Fatalf("Root = %q, want empty", env.Root)
	}
}

func TestDefaultModelForProvider(t *testing.T) {
	tests := map[string]string{
		"claude": "opus[1m]",
		"codex":  "gpt-5.6-sol",
		"gemini": "gemini-3.1-pro-preview",
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

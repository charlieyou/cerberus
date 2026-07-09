package generate

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestExtractDraftTextCodexUnwrapsLastAgentMessage(t *testing.T) {
	stdout := strings.Join([]string{
		`{"type":"thread.started","thread_id":"thread"}`,
		`{"type":"turn.started"}`,
		`{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"intermediate"}}`,
		`{"type":"item.completed","item":{"id":"item_1","type":"command_execution","text":"` + strings.Repeat("x", 4096) + `"}}`,
		`{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"# Codex Draft\n\nFinal spec body."}}`,
		`{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}`,
	}, "\n")

	got, err := extractDraftText("codex", []byte(stdout))
	if err != nil {
		t.Fatalf("extractDraftText() error = %v", err)
	}
	want := "# Codex Draft\n\nFinal spec body."
	if string(got) != want {
		t.Fatalf("extractDraftText() = %q, want %q", got, want)
	}
	if strings.Contains(string(got), "command_execution") || strings.Contains(string(got), "thread.started") {
		t.Fatalf("extractDraftText() leaked transcript events: %q", got)
	}
}

func TestExtractDraftTextCodexPlainTextPassesThrough(t *testing.T) {
	// The codex mock (and any non-stream output) emits plain markdown; it must
	// pass through unchanged rather than be treated as a malformed stream.
	stdout := []byte("# codex draft\n\nbody\n")
	got, err := extractDraftText("codex", stdout)
	if err != nil {
		t.Fatalf("extractDraftText() error = %v", err)
	}
	if string(got) != string(stdout) {
		t.Fatalf("extractDraftText() = %q, want pass-through %q", got, stdout)
	}
}

func TestExtractDraftTextCodexStreamWithoutAgentMessageFails(t *testing.T) {
	stdout := strings.Join([]string{
		`{"type":"thread.started","thread_id":"thread"}`,
		`{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}`,
	}, "\n")
	_, err := extractDraftText("codex", []byte(stdout))
	if err == nil || !strings.Contains(err.Error(), "no completed agent_message found") {
		t.Fatalf("extractDraftText() error = %v, want missing agent_message error", err)
	}
}

func TestExtractDraftTextCodexTruncatedStreamKeepsCapturedMessage(t *testing.T) {
	// A stream truncated mid-event still yields the last agent_message seen
	// before the break, rather than discarding a usable draft.
	stdout := strings.Join([]string{
		`{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"partial draft"}}`,
		`{"type":"item.completed","item":{"id":"item_1",`,
	}, "\n")
	got, err := extractDraftText("codex", []byte(stdout))
	if err != nil {
		t.Fatalf("extractDraftText() error = %v", err)
	}
	if string(got) != "partial draft" {
		t.Fatalf("extractDraftText() = %q, want %q", got, "partial draft")
	}
}

func TestExtractDraftTextClaudeUnwrapsResult(t *testing.T) {
	stdout := []byte(`{"type":"result","subtype":"success","is_error":false,"result":"# Claude Spec\n\nBody.","usage":{"input_tokens":11,"output_tokens":5}}`)
	got, err := extractDraftText("claude", stdout)
	if err != nil {
		t.Fatalf("extractDraftText() error = %v", err)
	}
	if string(got) != "# Claude Spec\n\nBody." {
		t.Fatalf("extractDraftText() = %q, want unwrapped result", got)
	}
}

func TestExtractDraftTextGeminiUnwrapsResponse(t *testing.T) {
	stdout := []byte(`{"response":"# Gemini Spec\n\nBody.","stats":{"models":{}}}`)
	got, err := extractDraftText("gemini", stdout)
	if err != nil {
		t.Fatalf("extractDraftText() error = %v", err)
	}
	if string(got) != "# Gemini Spec\n\nBody." {
		t.Fatalf("extractDraftText() = %q, want unwrapped response", got)
	}
}

func TestExtractDraftTextPlainMarkdownPassesThrough(t *testing.T) {
	// Mock providers emit plain markdown; it must pass through every provider
	// unchanged so the byte-for-byte fixture contract holds.
	stdout := []byte("# Plain Draft\n\nbody\n")
	for _, provider := range []string{"claude", "codex", "gemini", "unknown"} {
		got, err := extractDraftText(provider, stdout)
		if err != nil {
			t.Fatalf("extractDraftText(%s) error = %v", provider, err)
		}
		if string(got) != string(stdout) {
			t.Fatalf("extractDraftText(%s) = %q, want pass-through", provider, got)
		}
	}
}

func TestExtractDraftTextEnvelopeWithoutFieldPassesThrough(t *testing.T) {
	// A JSON object that is not the provider's own wrapper (no result/response
	// field) is left untouched rather than mangled.
	stdout := []byte(`{"type":"item.completed","item":{"type":"agent_message","text":"ignored"}}`)
	for _, provider := range []string{"claude", "gemini"} {
		got, err := extractDraftText(provider, stdout)
		if err != nil {
			t.Fatalf("extractDraftText(%s) error = %v", provider, err)
		}
		if string(got) != string(stdout) {
			t.Fatalf("extractDraftText(%s) = %q, want pass-through", provider, got)
		}
	}
}

func TestExtractDraftTextRecognizesEmptyEnvelopeField(t *testing.T) {
	// A present-but-empty wrapper field is recognized and unwrapped to empty so
	// the caller's empty-draft guard rejects the run instead of writing the
	// envelope as the draft.
	cases := []struct {
		provider string
		stdout   string
	}{
		{"claude", `{"type":"result","result":""}`},
		{"gemini", `{"response":""}`},
	}
	for _, tc := range cases {
		got, err := extractDraftText(tc.provider, []byte(tc.stdout))
		if err != nil {
			t.Fatalf("extractDraftText(%s) error = %v", tc.provider, err)
		}
		if len(got) != 0 {
			t.Fatalf("extractDraftText(%s) = %q, want empty unwrapped value", tc.provider, got)
		}
	}
}

func TestGenerateRunUnwrapsClaudeAndGeminiEnvelopes(t *testing.T) {
	cases := []struct {
		provider string
		stdout   string
		want     string
	}{
		{
			provider: "claude",
			stdout:   `{"type":"result","subtype":"success","result":"# Claude Spec\n\nThe real draft.","usage":{"input_tokens":11,"output_tokens":5}}`,
			want:     "# Claude Spec\n\nThe real draft.",
		},
		{
			provider: "gemini",
			stdout:   `{"response":"# Gemini Spec\n\nThe real draft.","stats":{"models":{}}}`,
			want:     "# Gemini Spec\n\nThe real draft.",
		},
	}
	for _, tc := range cases {
		t.Run(tc.provider, func(t *testing.T) {
			root := t.TempDir()
			writeGeneratorPolicy(t, root)
			writeGeneratePrompt(t, root, "prompts/generators/create-spec.md", "create spec generator")

			originalRunner := providerRunner
			providerRunner = func(ctx context.Context, root, providerName, model, effort, mode, instanceID, systemPrompt, userPrompt string) ([]byte, []byte, error) {
				return []byte(tc.stdout), nil, nil
			}
			t.Cleanup(func() { providerRunner = originalRunner })

			outputDir := t.TempDir()
			if err := Run(context.Background(), Options{
				OutputDir:     outputDir,
				Type:          "create-spec",
				Mode:          "smart",
				Prompt:        "fixture prompt",
				Root:          root,
				Panel:         testPanel(tc.provider),
				SkipInterview: true,
			}); err != nil {
				t.Fatalf("Run() error = %v", err)
			}

			assertFileContent(t, filepath.Join(outputDir, tc.provider, "draft.md"), tc.want)
			assertFileContent(t, filepath.Join(outputDir, tc.provider, "raw.json"), tc.stdout)
			stats := readStatsFile(t, filepath.Join(outputDir, tc.provider, "stats.json"))
			if stats.ExitCode != 0 {
				t.Fatalf("%s stats exit_code = %d, want 0", tc.provider, stats.ExitCode)
			}
		})
	}
}

func TestGenerateRunFailsOnEmptyClaudeResult(t *testing.T) {
	root := t.TempDir()
	writeGeneratorPolicy(t, root)
	writeGeneratePrompt(t, root, "prompts/generators/create-spec.md", "create spec generator")

	originalRunner := providerRunner
	providerRunner = func(ctx context.Context, root, providerName, model, effort, mode, instanceID, systemPrompt, userPrompt string) ([]byte, []byte, error) {
		return []byte(`{"type":"result","result":"   "}`), nil, nil
	}
	t.Cleanup(func() { providerRunner = originalRunner })

	outputDir := t.TempDir()
	err := Run(context.Background(), Options{
		OutputDir:     outputDir,
		Type:          "create-spec",
		Mode:          "smart",
		Prompt:        "fixture prompt",
		Root:          root,
		Panel:         testPanel("claude"),
		SkipInterview: true,
	})
	if err == nil || !strings.Contains(err.Error(), "produced empty draft") {
		t.Fatalf("Run() error = %v, want empty draft failure", err)
	}
	if _, statErr := os.Stat(filepath.Join(outputDir, "claude", "draft.md")); !os.IsNotExist(statErr) {
		t.Fatalf("claude draft stat err = %v, want not exist", statErr)
	}
	if _, statErr := os.Stat(filepath.Join(outputDir, "claude.failed")); statErr != nil {
		t.Fatalf("claude.failed stat err = %v, want exist", statErr)
	}
}

func TestGenerateRunWritesCodexDraftFromAgentMessage(t *testing.T) {
	root := t.TempDir()
	writeGeneratorPolicy(t, root)
	writeGeneratePrompt(t, root, "prompts/generators/create-spec.md", "create spec generator")

	stream := strings.Join([]string{
		`{"type":"thread.started","thread_id":"thread"}`,
		`{"type":"item.completed","item":{"id":"item_0","type":"command_execution","text":"` + strings.Repeat("x", 4096) + `"}}`,
		`{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"# Codex Spec\n\nThe real draft."}}`,
		`{"type":"turn.completed","usage":{"input_tokens":11,"output_tokens":5}}`,
	}, "\n")

	originalRunner := providerRunner
	providerRunner = func(ctx context.Context, root, providerName, model, effort, mode, instanceID, systemPrompt, userPrompt string) ([]byte, []byte, error) {
		return []byte(stream), nil, nil
	}
	t.Cleanup(func() { providerRunner = originalRunner })

	outputDir := t.TempDir()
	if err := Run(context.Background(), Options{
		OutputDir:     outputDir,
		Type:          "create-spec",
		Mode:          "smart",
		Prompt:        "fixture prompt",
		Root:          root,
		Panel:         testPanel("codex"),
		SkipInterview: true,
	}); err != nil {
		t.Fatalf("Run() error = %v", err)
	}

	// draft.md holds only the extracted agent_message, not the event stream.
	assertFileContent(t, filepath.Join(outputDir, "codex", "draft.md"), "# Codex Spec\n\nThe real draft.")
	// raw.json preserves the full JSONL stream for debugging.
	assertFileContent(t, filepath.Join(outputDir, "codex", "raw.json"), stream)

	stats := readStatsFile(t, filepath.Join(outputDir, "codex", "stats.json"))
	if stats.ExitCode != 0 {
		t.Fatalf("codex stats exit_code = %d, want 0", stats.ExitCode)
	}
}

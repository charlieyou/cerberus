package generate

import "testing"

func TestStatsParseProviderJSONClaudeEnvelope(t *testing.T) {
	raw, stats, err := ParseProviderJSON("claude", []byte(`{"usage":{"input_tokens":120,"output_tokens":35},"total_cost_usd":0.004}`))
	if err != nil {
		t.Fatalf("ParseProviderJSON() error = %v", err)
	}
	if string(raw) != `{"usage":{"input_tokens":120,"output_tokens":35},"total_cost_usd":0.004}` {
		t.Fatalf("raw = %q, want canonical envelope", raw)
	}
	assertParsedStats(t, stats, 120, 35, 0.004)
}

func TestStatsParseProviderJSONCodexEnvelope(t *testing.T) {
	_, stats, err := ParseProviderJSON("codex", []byte(`{"usage":{"prompt_tokens":50,"completion_tokens":20},"cost_usd":0.002}`))
	if err != nil {
		t.Fatalf("ParseProviderJSON() error = %v", err)
	}
	assertParsedStats(t, stats, 50, 20, 0.002)
}

func TestStatsParseProviderJSONCodexJSONL(t *testing.T) {
	stdout := []byte(`{"type":"turn.started"}
{"type":"turn.completed","usage":{"input_tokens":1200,"output_tokens":400}}
{"type":"turn.completed","usage":{"input_tokens":300,"output_tokens":50},"cost_usd":0.002}
`)

	raw, stats, err := ParseProviderJSON("codex", stdout)
	if err != nil {
		t.Fatalf("ParseProviderJSON() error = %v", err)
	}
	if string(raw) != string(stdout[:len(stdout)-1]) {
		t.Fatalf("raw = %q, want trimmed JSONL stdout", raw)
	}
	assertParsedStats(t, stats, 1500, 450, 0.002)
}

func TestStatsParseProviderJSONGeminiEnvelope(t *testing.T) {
	_, stats, err := ParseProviderJSON("gemini", []byte(`{"stats":{"cost":0.003,"models":{"gemini-3.1-pro":{"tokens":{"input":70,"candidates":25}}}}}`))
	if err != nil {
		t.Fatalf("ParseProviderJSON() error = %v", err)
	}
	assertParsedStats(t, stats, 70, 25, 0.003)
}

func TestStatsParseProviderJSONPlainMarkdownFallback(t *testing.T) {
	raw, stats, err := ParseProviderJSON("claude", []byte("# draft\n"))
	if err != nil {
		t.Fatalf("ParseProviderJSON() error = %v", err)
	}
	if raw != nil {
		t.Fatalf("raw = %q, want nil", raw)
	}
	if stats.Tokens != nil {
		t.Fatalf("tokens = %#v, want nil", stats.Tokens)
	}
	if stats.CostUSD != nil {
		t.Fatalf("cost = %#v, want nil", stats.CostUSD)
	}
}

func assertParsedStats(t *testing.T, stats Stats, input, output int, cost float64) {
	t.Helper()
	if stats.Tokens == nil {
		t.Fatal("tokens = nil, want parsed tokens")
	}
	if stats.Tokens.Input != input || stats.Tokens.Output != output {
		t.Fatalf("tokens = %#v, want input=%d output=%d", stats.Tokens, input, output)
	}
	if stats.CostUSD == nil {
		t.Fatal("cost = nil, want parsed cost")
	}
	if *stats.CostUSD != cost {
		t.Fatalf("cost = %v, want %v", *stats.CostUSD, cost)
	}
}

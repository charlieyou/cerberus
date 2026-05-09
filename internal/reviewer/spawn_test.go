package reviewer

import "testing"

func TestExtractUsagePreservesProviderFormats(t *testing.T) {
	t.Run("codex jsonl", func(t *testing.T) {
		stdout := []byte(`{"type":"turn.started"}
{"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":100,"output_tokens":400}}
{"type":"turn.completed","usage":{"input_tokens":300,"output_tokens":50}}
`)

		tokens, costUSD := extractUsage(stdout)

		if tokens.Input != 1500 || tokens.Output != 450 {
			t.Fatalf("tokens = %#v, want input=1500 output=450", tokens)
		}
		if costUSD != 0 {
			t.Fatalf("costUSD = %v, want 0", costUSD)
		}
	})

	t.Run("gemini nested stats", func(t *testing.T) {
		stdout := []byte(`{
  "stats": {
    "cost": 0.012,
    "models": {
      "gemini-2.5-pro": {
        "tokens": {
          "input": 700,
          "candidates": 250,
          "cached": 50
        }
      }
    }
  }
}`)

		tokens, costUSD := extractUsage(stdout)

		if tokens.Input != 700 || tokens.Output != 250 {
			t.Fatalf("tokens = %#v, want input=700 output=250", tokens)
		}
		if costUSD != 0.012 {
			t.Fatalf("costUSD = %v, want 0.012", costUSD)
		}
	})

	t.Run("claude top-level", func(t *testing.T) {
		stdout := []byte(`{"tokens":{"input":100,"output":50,"cached":10},"total_cost_usd":0.001}`)

		tokens, costUSD := extractUsage(stdout)

		if tokens.Input != 100 || tokens.Output != 50 {
			t.Fatalf("tokens = %#v, want input=100 output=50", tokens)
		}
		if costUSD != 0.001 {
			t.Fatalf("costUSD = %v, want 0.001", costUSD)
		}
	})
}

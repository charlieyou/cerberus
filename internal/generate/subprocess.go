package generate

import (
	"context"

	"github.com/charlieyou/cerberus/internal/reviewer"
)

func runProvider(ctx context.Context, root, providerName, model, instanceID, systemPrompt, userPrompt string) ([]byte, []byte, error) {
	if instanceID == "" {
		instanceID = providerName + "#1"
	}
	output, err := reviewer.RunProvider(ctx, reviewer.ProviderInvocation{
		// Label keys human-facing error text ("generator codex failed"); keep it
		// the provider name. InstanceID (codex#1, codex#2) keys the reviewer
		// identity, replay fixtures, and mock recording.
		Label:              "generator " + providerName,
		InstanceID:         instanceID,
		Provider:           providerName,
		Model:              model,
		System:             []byte(systemPrompt),
		User:               []byte(userPrompt),
		Root:               root,
		ClaudeOutputFormat: "json",
		// Emit Claude's --model so a roster-selected Claude model is honored
		// (matches the reviewer path, which always sets this). Without it,
		// Claude drafter slots silently fall back to the CLI default model.
		ClaudeModelFlag: true,
	})
	return output.Stdout, output.Stderr, err
}

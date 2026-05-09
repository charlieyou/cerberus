package generate

import (
	"context"

	"github.com/charlieyou/cerberus/internal/reviewer"
)

func runProvider(ctx context.Context, root, providerName, model, systemPrompt, userPrompt string) ([]byte, []byte, error) {
	output, err := reviewer.RunProvider(ctx, reviewer.ProviderInvocation{
		Label:              "generator " + providerName,
		Provider:           providerName,
		Model:              model,
		System:             []byte(systemPrompt),
		User:               []byte(userPrompt),
		Root:               root,
		ClaudeOutputFormat: "json",
	})
	return output.Stdout, output.Stderr, err
}

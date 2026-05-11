package prompts

import (
	"fmt"
)

const generatorPromptDir = "prompts/generators"

// ComposeGenerator reads the on-disk generator system prompt for a provider and
// generator type. Templates are intentionally read on every call.
func ComposeGenerator(provider, generatorType string) (string, error) {
	root, err := rootDir()
	if err != nil {
		return "", err
	}
	return ComposeGeneratorFromRoot(root, provider, generatorType)
}

// ComposeGeneratorFromRoot is ComposeGenerator with an explicit root for tests
// and callers that already resolved CERBERUS_ROOT.
func ComposeGeneratorFromRoot(root, provider, generatorType string) (string, error) {
	if provider == "" {
		return "", fmt.Errorf("generator provider is required")
	}
	if generatorType == "" {
		return "", fmt.Errorf("generator type is required")
	}
	return readGeneratorPrompt(root, provider, generatorType)
}

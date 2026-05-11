package prompts

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
)

const interviewPromptPath = "prompts/interview-engine.md"

// ComposeGeneratorWithOptions reads the generator system prompt and applies
// mode/interview options used by the generate CLI.
func ComposeGeneratorWithOptions(provider, generatorType, mode string, skipInterview bool) (string, error) {
	root, err := rootDir()
	if err != nil {
		return "", err
	}
	return ComposeGeneratorWithOptionsFromRoot(root, provider, generatorType, mode, skipInterview)
}

// ComposeGeneratorWithOptionsFromRoot is ComposeGeneratorWithOptions with an
// explicit prompt root for tests and callers that already resolved CERBERUS_ROOT.
func ComposeGeneratorWithOptionsFromRoot(root, provider, generatorType, mode string, skipInterview bool) (string, error) {
	if mode == "" {
		mode = "smart"
	}

	var parts [][]byte
	if !skipInterview && generatorUsesInterview(generatorType) {
		data, err := readPromptFile(filepath.Join(root, interviewPromptPath))
		if err != nil {
			return "", fmt.Errorf("read interview prompt: %w", err)
		}
		parts = append(parts, data)
	}

	generatorPrompt, err := readGeneratorPrompt(root, provider, generatorType)
	if err != nil {
		return "", err
	}
	parts = append(parts, []byte(generatorPrompt))

	preamble := "Cerberus generator type: " + generatorType + ".\nCerberus generate mode: " + mode + "."
	if provider != "" {
		preamble += "\nCerberus provider: " + provider + "."
	}
	return preamble + "\n\n" + string(bytes.Join(parts, []byte("\n\n"))), nil
}

func readGeneratorPrompt(root, provider, generatorType string) (string, error) {
	if provider == "" {
		return "", fmt.Errorf("generator provider is required")
	}
	if generatorType == "" {
		return "", fmt.Errorf("generator type is required")
	}

	providerPath := filepath.Join(root, "prompts/generators", generatorType, provider+".md")
	data, err := readPromptFile(providerPath)
	if err == nil {
		return string(data), nil
	}
	if !os.IsNotExist(err) {
		return "", fmt.Errorf("read generator prompt %s/%s: %w", generatorType, provider, err)
	}

	flatPath := filepath.Join(root, "prompts/generators", generatorType+".md")
	data, err = readPromptFile(flatPath)
	if err != nil {
		return "", fmt.Errorf("read generator prompt %s/%s: %w", generatorType, provider, err)
	}
	return string(data), nil
}

func generatorUsesInterview(generatorType string) bool {
	switch generatorType {
	case "create-spec", "create-plan":
		return true
	default:
		return false
	}
}

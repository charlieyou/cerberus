package integration_test

import "testing"

func TestGenerateCreateSpec(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	root := newGeneratePromptRoot(t, "create-spec", "create-spec template v1")
	promptFile := writePromptFile(t, "write a create-spec draft")

	first := runGenerateCommand(t, repoRoot, binary, root, "--type", "create-spec", "--mode", "smart", "--prompt-file", promptFile)
	assertGenerateOutputs(t, repoRoot, first.outputDir, "create-spec")
	assertRecordedSystemPromptContains(t, first.recordDir, "create-spec", "create-spec template v1")

	writeGeneratorTemplates(t, root, "create-spec", "create-spec template v2")
	second := runGenerateCommand(t, repoRoot, binary, root, "--type", "create-spec", "--mode", "smart", "--prompt-file", promptFile)
	assertGenerateOutputs(t, repoRoot, second.outputDir, "create-spec")
	assertRecordedSystemPromptContains(t, second.recordDir, "create-spec", "create-spec template v2")
}

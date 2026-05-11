package integration_test

import "testing"

func TestGenerateArchitectureReview(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	root := newGeneratePromptRoot(t, "architecture-review", "architecture-review template v1")
	promptFile := writePromptFile(t, "write an architecture-review draft")

	first := runGenerateCommand(t, repoRoot, binary, root, "--type", "architecture-review", "--mode", "smart", "--prompt-file", promptFile)
	assertGenerateOutputs(t, repoRoot, first.outputDir, "architecture-review")
	assertRecordedSystemPromptContains(t, first.recordDir, "architecture-review", "architecture-review template v1")

	writeGeneratorTemplates(t, root, "architecture-review", "architecture-review template v2")
	second := runGenerateCommand(t, repoRoot, binary, root, "--type", "architecture-review", "--mode", "smart", "--prompt-file", promptFile)
	assertGenerateOutputs(t, repoRoot, second.outputDir, "architecture-review")
	assertRecordedSystemPromptContains(t, second.recordDir, "architecture-review", "architecture-review template v2")
}

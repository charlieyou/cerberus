package integration_test

import "testing"

func TestGenerateCreatePlan(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	root := newGeneratePromptRoot(t, "create-plan", "create-plan template v1")
	promptFile := writePromptFile(t, "write a create-plan draft")

	first := runGenerateCommand(t, repoRoot, binary, root, "--type", "create-plan", "--mode", "smart", "--prompt-file", promptFile)
	assertGenerateOutputs(t, repoRoot, first.outputDir, "create-plan")
	assertRecordedSystemPromptContains(t, first.recordDir, "create-plan", "create-plan template v1")

	writeGeneratorTemplates(t, root, "create-plan", "create-plan template v2")
	second := runGenerateCommand(t, repoRoot, binary, root, "--type", "create-plan", "--mode", "smart", "--prompt-file", promptFile)
	assertGenerateOutputs(t, repoRoot, second.outputDir, "create-plan")
	assertRecordedSystemPromptContains(t, second.recordDir, "create-plan", "create-plan template v2")
}

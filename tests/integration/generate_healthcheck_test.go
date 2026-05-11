package integration_test

import "testing"

func TestGenerateHealthcheck(t *testing.T) {
	repoRoot := integrationRepoRoot(t)
	binary := buildIntegrationCerberus(t, repoRoot)
	root := newGeneratePromptRoot(t, "healthcheck", "healthcheck template v1")
	focus := "review error handling"

	first := runGenerateCommand(t, repoRoot, binary, root, "--type", "healthcheck", "--focus", focus)
	assertGenerateOutputs(t, repoRoot, first.outputDir, "healthcheck")
	assertGenerateStdin(t, first.recordDir, focus)
	assertRecordedSystemPromptContains(t, first.recordDir, "healthcheck", "healthcheck template v1")

	writeGeneratorTemplates(t, root, "healthcheck", "healthcheck template v2")
	second := runGenerateCommand(t, repoRoot, binary, root, "--type", "healthcheck", "--focus", focus)
	assertGenerateOutputs(t, repoRoot, second.outputDir, "healthcheck")
	assertGenerateStdin(t, second.recordDir, focus)
	assertRecordedSystemPromptContains(t, second.recordDir, "healthcheck", "healthcheck template v2")
}

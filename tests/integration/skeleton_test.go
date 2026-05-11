package integration_test

import (
	"os/exec"
	"path/filepath"
	"testing"
)

func TestCerberusCheckSkeleton(t *testing.T) {
	repoRoot := filepath.Join("..", "..")
	binary := filepath.Join(t.TempDir(), "cerberus")

	build := exec.Command("go", "build", "-o", binary, "./cmd/cerberus")
	build.Dir = repoRoot
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build ./cmd/cerberus failed: %v\n%s", err, output)
	}

	check := exec.Command(binary, "check")
	output, err := check.CombinedOutput()
	if err != nil {
		t.Fatalf("cerberus check failed: %v\n%s", err, output)
	}
	if got, want := string(output), "no active review\n"; got != want {
		t.Fatalf("cerberus check output = %q, want %q", got, want)
	}
}

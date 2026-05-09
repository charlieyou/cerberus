package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestRunCheck(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run([]string{"check"}, &stdout, &stderr)

	if code != 0 {
		t.Fatalf("run(check) exit code = %d, want 0; stderr: %s", code, stderr.String())
	}
	if got, want := stdout.String(), "no active review\n"; got != want {
		t.Fatalf("run(check) stdout = %q, want %q", got, want)
	}
	if stderr.Len() != 0 {
		t.Fatalf("run(check) stderr = %q, want empty", stderr.String())
	}
}

func TestRunUnknownSubcommand(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run([]string{"bogus"}, &stdout, &stderr)

	if code == 0 {
		t.Fatal("run(unknown) exit code = 0, want non-zero")
	}
	if stdout.Len() != 0 {
		t.Fatalf("run(unknown) stdout = %q, want empty", stdout.String())
	}
	if got := stderr.String(); !strings.Contains(got, `unknown subcommand "bogus"`) || !strings.Contains(got, "usage: cerberus") {
		t.Fatalf("run(unknown) stderr = %q, want unknown-subcommand error and usage", got)
	}
}

func TestRunMissingSubcommand(t *testing.T) {
	var stdout, stderr bytes.Buffer

	code := run(nil, &stdout, &stderr)

	if code == 0 {
		t.Fatal("run(no args) exit code = 0, want non-zero")
	}
	if stdout.Len() != 0 {
		t.Fatalf("run(no args) stdout = %q, want empty", stdout.String())
	}
	if got := stderr.String(); !strings.Contains(got, "usage: cerberus") {
		t.Fatalf("run(no args) stderr = %q, want usage", got)
	}
}

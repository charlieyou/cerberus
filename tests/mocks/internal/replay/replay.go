package replay

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const passResponse = `{"findings":[]}` + "\n"

func Main(provider string) {
	if err := validateInvocation(provider, os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "mock-%s: unsupported argv: %v\n", provider, err)
		os.Exit(2)
	}

	prompt, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mock-%s: read stdin: %v\n", provider, err)
		os.Exit(1)
	}
	recordInvocation(provider, prompt)

	if code := os.Getenv("CERBERUS_MOCK_EXIT"); code != "" && code != "0" {
		fmt.Fprintln(os.Stderr, "mock exit")
		os.Exit(atoiExit(code))
	}
	if os.Getenv("CERBERUS_MOCK_EMPTY_STDOUT") == "1" {
		return
	}
	if fixtureDir := os.Getenv("CERBERUS_FIXTURE_DIR"); fixtureDir != "" {
		replayFixture(provider, fixtureDir, prompt)
		return
	}
	fmt.Print(passResponse)
}

func validateInvocation(provider string, args []string) error {
	switch provider {
	case "claude":
		return validateClaudeArgs(args)
	case "codex":
		return validateCodexArgs(args)
	case "gemini":
		return validateGeminiArgs(args)
	default:
		return fmt.Errorf("unknown provider %q", provider)
	}
}

func validateClaudeArgs(args []string) error {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--print", "-p", "--restricted", "--help", "-h", "--version", "-v":
		case "--output-format":
			value, next, err := requireValue(args, i)
			if err != nil {
				return err
			}
			if value != "json" && value != "text" && value != "stream-json" {
				return fmt.Errorf("unsupported claude output format %q", value)
			}
			i = next
		case "--model", "--append-system-prompt", "--effort", "--tools":
			_, next, err := requireValue(args, i)
			if err != nil {
				return err
			}
			i = next
		default:
			if strings.HasPrefix(args[i], "-") {
				return fmt.Errorf("unsupported claude flag %q", args[i])
			}
		}
	}
	return nil
}

func validateCodexArgs(args []string) error {
	if len(args) == 0 {
		return nil
	}
	if args[0] != "exec" && args[0] != "e" {
		return fmt.Errorf("codex mock expects non-interactive exec subcommand, got %q", args[0])
	}
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--json", "--help", "-h", "--version", "-V":
		case "--model", "-m", "--config", "-c":
			_, next, err := requireValue(args, i)
			if err != nil {
				return err
			}
			i = next
		default:
			if strings.HasPrefix(args[i], "-") {
				return fmt.Errorf("unsupported codex exec flag %q", args[i])
			}
			return nil
		}
	}
	return nil
}

func validateGeminiArgs(args []string) error {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--help", "-h", "--version", "-v", "--skip-trust":
		case "--output-format", "-o":
			value, next, err := requireValue(args, i)
			if err != nil {
				return err
			}
			if value != "json" && value != "text" && value != "stream-json" {
				return fmt.Errorf("unsupported gemini output format %q", value)
			}
			i = next
		case "--model", "-m", "--prompt", "-p", "--policy", "--admin-policy", "--approval-mode":
			_, next, err := requireValue(args, i)
			if err != nil {
				return err
			}
			i = next
		default:
			if strings.HasPrefix(args[i], "-") {
				return fmt.Errorf("unsupported gemini flag %q", args[i])
			}
		}
	}
	return nil
}

func requireValue(args []string, index int) (string, int, error) {
	if index+1 >= len(args) {
		return "", index, fmt.Errorf("%s requires a value", args[index])
	}
	value := args[index+1]
	if value == "" {
		return "", index, fmt.Errorf("%s requires a non-empty value", args[index])
	}
	if strings.HasPrefix(value, "-") {
		return "", index, errors.New(args[index] + " value looks like another flag")
	}
	return value, index + 1, nil
}

func recordInvocation(provider string, prompt []byte) {
	recordDir := os.Getenv("CERBERUS_MOCK_RECORD_DIR")
	if recordDir == "" {
		return
	}
	_ = os.MkdirAll(recordDir, 0o755)
	_ = os.WriteFile(filepath.Join(recordDir, provider+".stdin"), prompt, 0o644)
	if settingsPath := os.Getenv("GEMINI_CLI_SYSTEM_SETTINGS_PATH"); provider == "gemini" && settingsPath != "" {
		if settings, err := os.ReadFile(settingsPath); err == nil {
			_ = os.WriteFile(filepath.Join(recordDir, provider+".settings.json"), settings, 0o644)
		}
	}
	args := strings.Join(os.Args[1:], "\n")
	if args != "" {
		args += "\n"
	}
	_ = os.WriteFile(filepath.Join(recordDir, provider+".args"), []byte(args), 0o644)
	sum := sha256.Sum256(prompt)
	stats := fmt.Sprintf("{\"prompt_sha256\":\"%s\"}\n", hex.EncodeToString(sum[:]))
	_ = os.WriteFile(filepath.Join(recordDir, provider+".stats.json"), []byte(stats), 0o644)
}

func replayFixture(provider, fixtureDir string, prompt []byte) {
	sum := sha256.Sum256(prompt)
	instanceID := os.Getenv("CERBERUS_MOCK_INSTANCE_ID")
	if instanceID == "" {
		instanceID = provider + "#1"
	}
	key := hex.EncodeToString(sum[:8]) + ":" + instanceID
	fixturePath := filepath.Join(fixtureDir, key+".json")
	body, err := os.ReadFile(fixturePath)
	if err != nil {
		capturePath := fixturePath + ".prompt.txt"
		_ = os.WriteFile(capturePath, prompt, 0o644)
		fmt.Fprintf(os.Stderr, "mock-%s: no fixture for prompt+instance; wrote %s\n", provider, capturePath)
		os.Exit(2)
	}
	_, _ = os.Stdout.Write(body)
}

func atoiExit(value string) int {
	var code int
	if _, err := fmt.Sscanf(value, "%d", &code); err != nil || code < 0 || code > 125 {
		return 1
	}
	return code
}

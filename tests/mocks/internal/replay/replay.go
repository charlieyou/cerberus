package replay

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const passResponse = `{"findings":[],"verdict":"PASS","summary":"mock pass","overall_confidence":0.9,"strategy":"mock","round":1,"peer_responses_seen":[]}` + "\n"

func Main(provider string) {
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

func recordInvocation(provider string, prompt []byte) {
	recordDir := os.Getenv("CERBERUS_MOCK_RECORD_DIR")
	if recordDir == "" {
		return
	}
	_ = os.MkdirAll(recordDir, 0o755)
	_ = os.WriteFile(filepath.Join(recordDir, provider+".stdin"), prompt, 0o644)
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

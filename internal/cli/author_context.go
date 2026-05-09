package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charlieyou/cerberus/internal/state"
)

func runAuthorContext(args []string, stdout, stderr io.Writer) int {
	var clear bool
	fs := flag.NewFlagSet("author-context", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.BoolVar(&clear, "clear", false, "clear author context")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	runRoot, ok, err := activeRunRoot()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	if !ok {
		fmt.Fprintln(stderr, "CERBERUS_RUN_KEY or CERBERUS_SESSION_ID is required")
		return 1
	}
	path := filepath.Join(runRoot, "author-context.json")
	if clear {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			fmt.Fprintln(stderr, err)
			return 1
		}
		fmt.Fprintln(stdout, "cleared")
		return 0
	}
	text := strings.Join(fs.Args(), " ")
	if text == "" {
		data, err := os.ReadFile(path)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return printNoActiveStatus(stdout, false)
			}
			fmt.Fprintln(stderr, err)
			return 1
		}
		fmt.Fprint(stdout, string(data))
		return 0
	}
	if err := state.EnsureRunDir(runRoot); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	data, err := json.MarshalIndent(map[string]string{
		"text":       text,
		"updated_at": time.Now().UTC().Format(time.RFC3339),
	}, "", "  ")
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	data = append(data, '\n')
	if err := os.WriteFile(path, data, 0o644); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	fmt.Fprintln(stdout, "saved")
	return 0
}

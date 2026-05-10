package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func main() {
	if err := run("."); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("zero-bash lint: ok")
}

func run(root string) error {
	var failures []string
	tracked, err := gitTrackedBinFiles(root)
	if err != nil {
		return err
	}
	for _, rel := range tracked {
		if rel != "bin/cerberus" {
			failures = append(failures, fmt.Sprintf("%s: tracked bin/ file is not allowed; only bin/cerberus may appear", rel))
		}
	}
	if err := filepath.WalkDir(filepath.Join(root, "bin"), func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", path, err))
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", path, err))
			return nil
		}
		rel = filepath.ToSlash(rel)
		if shellShebang(path) {
			failures = append(failures, fmt.Sprintf("%s: shell shebangs under bin/ are forbidden", rel))
		}
		return nil
	}); err != nil && !os.IsNotExist(err) {
		return err
	}
	if len(failures) > 0 {
		return fmt.Errorf("zero-bash lint failed:\n%s", strings.Join(failures, "\n"))
	}
	return nil
}

func gitTrackedBinFiles(root string) ([]string, error) {
	cmd := exec.Command("git", "ls-files", "bin/")
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("git ls-files bin/: %w", err)
	}
	var paths []string
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		if text := strings.TrimSpace(scanner.Text()); text != "" {
			paths = append(paths, filepath.ToSlash(text))
		}
	}
	return paths, scanner.Err()
}

func shellShebang(path string) bool {
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	if !scanner.Scan() {
		return false
	}
	line := strings.TrimSpace(scanner.Text())
	if !strings.HasPrefix(line, "#!") {
		return false
	}
	interp := strings.TrimSpace(strings.TrimPrefix(line, "#!"))
	fields := strings.Fields(interp)
	if len(fields) == 0 {
		return false
	}
	name := filepath.Base(fields[0])
	if name == "env" && len(fields) > 1 {
		name = filepath.Base(fields[1])
	}
	switch name {
	case "sh", "bash", "dash", "zsh":
		return true
	default:
		return false
	}
}

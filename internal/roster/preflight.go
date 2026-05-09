package roster

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"

	"gopkg.in/yaml.v3"
)

var rosterNamePattern = regexp.MustCompile(`^[a-z0-9_-]+$`)

func rejectUnknownFields(data []byte, path string) error {
	var node yaml.Node
	if err := yaml.Unmarshal(data, &node); err != nil {
		return fmt.Errorf("roster preflight %s roster %q slot %d: schema parse error: %w", path, defaultRosterName, 0, err)
	}
	if len(node.Content) == 0 {
		return nil
	}
	root := node.Content[0]
	if root.Kind != yaml.MappingNode {
		return fmt.Errorf("roster preflight %s roster %q slot %d: schema parse error: top-level document must be a mapping", path, defaultRosterName, 0)
	}

	top := map[string]bool{"version": true, "defaults": true, "rosters": true}
	defaults := map[string]bool{"mode": true, "max_rounds": true}
	rosterFields := map[string]bool{"reviewers": true}
	slotFields := map[string]bool{"provider": true, "model": true, "strategy": true, "persona": true, "mode": true}

	for i := 0; i < len(root.Content); i += 2 {
		key := root.Content[i].Value
		value := root.Content[i+1]
		if !top[key] {
			return fmt.Errorf("roster preflight %s roster %q slot %d: unknown top-level key %q", path, defaultRosterName, 0, key)
		}
		if key == "defaults" {
			if err := rejectUnknownMappingFields(value, defaults, path, defaultRosterName, 0, "defaults"); err != nil {
				return err
			}
		}
		if key == "rosters" && value.Kind == yaml.MappingNode {
			for j := 0; j < len(value.Content); j += 2 {
				rosterName := value.Content[j].Value
				rosterNode := value.Content[j+1]
				if err := rejectUnknownMappingFields(rosterNode, rosterFields, path, rosterName, 0, "roster"); err != nil {
					return err
				}
				reviewers := mappingValue(rosterNode, "reviewers")
				if reviewers == nil || reviewers.Kind != yaml.SequenceNode {
					continue
				}
				for slotIndex, slotNode := range reviewers.Content {
					if err := rejectUnknownMappingFields(slotNode, slotFields, path, rosterName, slotIndex+1, "slot"); err != nil {
						return err
					}
				}
			}
		}
	}
	return nil
}

func rejectUnknownMappingFields(node *yaml.Node, allowed map[string]bool, path, rosterName string, slotIndex int, scope string) error {
	if node == nil || node.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i < len(node.Content); i += 2 {
		key := node.Content[i].Value
		if !allowed[key] {
			return fmt.Errorf("roster preflight %s roster %q slot %d: unknown %s key %q", path, rosterName, slotIndex, scope, key)
		}
	}
	return nil
}

func mappingValue(node *yaml.Node, key string) *yaml.Node {
	if node == nil || node.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i < len(node.Content); i += 2 {
		if node.Content[i].Value == key {
			return node.Content[i+1]
		}
	}
	return nil
}

func validateFile(file *RostersFile) error {
	path := filePath(file)
	if file.Version != 1 {
		return preflightError(path, defaultRosterName, 0, "version must be 1")
	}
	if file.Defaults.Mode != "" && !validMode(file.Defaults.Mode) {
		return preflightError(path, defaultRosterName, 0, "unknown mode %q", file.Defaults.Mode)
	}
	if file.Defaults.MaxRounds != nil && *file.Defaults.MaxRounds <= 0 {
		return preflightError(path, defaultRosterName, 0, "max_rounds must be positive")
	}
	if len(file.Rosters) == 0 {
		return preflightError(path, defaultRosterName, 0, "rosters must contain at least one roster")
	}
	for name, roster := range file.Rosters {
		if !rosterNamePattern.MatchString(name) {
			return preflightError(path, name, 0, "roster name must match [a-z0-9_-]+")
		}
		if len(roster.Reviewers) == 0 {
			return preflightError(path, name, 0, "reviewers must be non-empty")
		}
	}
	return nil
}

func validateSlots(file *RostersFile, rosterName string, slots []RosterSlot) error {
	path := filePath(file)
	for i, slot := range slots {
		slotIndex := i + 1
		if !validProvider(slot.Provider) {
			return preflightError(path, rosterName, slotIndex, "unknown provider %q", slot.Provider)
		}
		if slot.Model == "" {
			return preflightError(path, rosterName, slotIndex, "model is required")
		}
		if slot.Mode != "" && !validMode(slot.Mode) {
			return preflightError(path, rosterName, slotIndex, "unknown mode %q", slot.Mode)
		}
		if slot.Strategy != "" && slot.Strategy != "none" {
			if err := validateStrategy(file, rosterName, slotIndex, slot.Strategy); err != nil {
				return err
			}
		}
		if slot.PersonaPath != "" {
			personaPath := resolveRosterRelativePath(file, slot.PersonaPath)
			if _, err := os.Stat(personaPath); err != nil {
				if os.IsNotExist(err) {
					return preflightError(path, rosterName, slotIndex, "persona file %q does not exist", personaPath)
				}
				return preflightError(path, rosterName, slotIndex, "inspect persona file %q: %v", personaPath, err)
			}
		}
		if _, err := exec.LookPath(slot.Provider); err != nil {
			return preflightError(path, rosterName, slotIndex, "provider CLI %q is not available on PATH", slot.Provider)
		}
	}
	return nil
}

func degradeBuiltInDefault(slots []RosterSlot) []RosterSlot {
	filtered := slots[:0]
	for _, slot := range slots {
		if _, err := exec.LookPath(slot.Provider); err != nil {
			fmt.Fprintf(os.Stderr, "warning: default panel CLI %q missing on PATH; skipping slot\n", slot.Provider)
			continue
		}
		filtered = append(filtered, slot)
	}
	return filtered
}

func validateStrategy(file *RostersFile, rosterName string, slotIndex int, strategy string) error {
	strategyPath := filepath.Join("prompts", "strategies", strategy+".md")
	if _, err := os.Stat(strategyPath); err != nil {
		if os.IsNotExist(err) {
			return preflightError(filePath(file), rosterName, slotIndex, "strategy file %q does not exist", strategyPath)
		}
		return preflightError(filePath(file), rosterName, slotIndex, "inspect strategy file %q: %v", strategyPath, err)
	}
	return nil
}

func warnDuplicates(w io.Writer, slots []RosterSlot) {
	triples := make(map[string]int)
	providerModels := make(map[string]int)
	for _, slot := range slots {
		triple := slot.Provider + "\x00" + slot.Model + "\x00" + slot.Strategy
		triples[triple]++
		if triples[triple] == 2 {
			fmt.Fprintf(w, "warning: duplicate reviewer slot tuple (provider=%s, model=%s, strategy=%s)\n", slot.Provider, slot.Model, slot.Strategy)
		}
		providerModel := slot.Provider + "\x00" + slot.Model
		providerModels[providerModel]++
		if providerModels[providerModel] == 11 {
			fmt.Fprintf(w, "warning: more than 10 reviewer instances for provider=%s model=%s\n", slot.Provider, slot.Model)
		}
	}
}

func resolveRosterRelativePath(file *RostersFile, path string) string {
	if filepath.IsAbs(path) || file == nil || file.FilePath == "" {
		return path
	}
	return filepath.Join(filepath.Dir(file.FilePath), path)
}

func validProvider(provider string) bool {
	switch provider {
	case "claude", "codex", "gemini":
		return true
	default:
		return false
	}
}

func validMode(mode string) bool {
	switch mode {
	case "fast", "smart", "max":
		return true
	default:
		return false
	}
}

func preflightError(path, rosterName string, slotIndex int, format string, args ...any) error {
	var message bytes.Buffer
	fmt.Fprintf(&message, "roster preflight %s roster %q slot %d: ", path, rosterName, slotIndex)
	fmt.Fprintf(&message, format, args...)
	return fmt.Errorf("%s", message.String())
}

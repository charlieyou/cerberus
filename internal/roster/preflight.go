package roster

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

var modeNamePattern = regexp.MustCompile(`^[a-z0-9_-]+$`)

const DebateMinimumReason = "debate_min_reviewers"

// PreflightError is a roster validation failure that carries the CLI exit code
// and telemetry reason expected by pre-run checks.
type PreflightError struct {
	Message string
	Code    int
	Reason  string
}

func (err PreflightError) Error() string {
	return err.Message
}

func (err PreflightError) ExitCode() int {
	return err.Code
}

func (err PreflightError) TelemetryReason() string {
	return err.Reason
}

func EnforceDebateMinimum(slots []RosterSlot, debate bool) error {
	if !debate || len(slots) >= 2 {
		return nil
	}
	return PreflightError{
		Message: fmt.Sprintf("--debate requires at least 2 reviewers in the resolved roster (got %d); see docs/debate.md for rationale", len(slots)),
		Code:    6,
		Reason:  DebateMinimumReason,
	}
}

func rejectUnknownFields(data []byte, path string) error {
	var node yaml.Node
	if err := yaml.Unmarshal(data, &node); err != nil {
		return fmt.Errorf("config preflight %s mode %q model %d: schema parse error: %w", path, defaultMode, 0, err)
	}
	if len(node.Content) == 0 {
		return nil
	}
	root := node.Content[0]
	if root.Kind != yaml.MappingNode {
		return fmt.Errorf("config preflight %s mode %q model %d: schema parse error: top-level document must be a mapping", path, defaultMode, 0)
	}

	top := map[string]bool{"version": true, "defaults": true, "roster": true}
	defaults := map[string]bool{"mode": true, "max_rounds": true}
	modeFields := map[string]bool{"models": true}
	modelFields := map[string]bool{"provider": true, "model": true, "effort": true, "strategy": true, "persona": true}

	for i := 0; i < len(root.Content); i += 2 {
		key := root.Content[i].Value
		value := root.Content[i+1]
		if !top[key] {
			return fmt.Errorf("config preflight %s mode %q model %d: unknown top-level key %q", path, defaultMode, 0, key)
		}
		if key == "defaults" {
			if err := rejectUnknownMappingFields(value, defaults, path, defaultMode, 0, "defaults"); err != nil {
				return err
			}
		}
		if key == "roster" && value.Kind == yaml.MappingNode {
			for j := 0; j < len(value.Content); j += 2 {
				mode := value.Content[j].Value
				modeNode := value.Content[j+1]
				if err := rejectUnknownMappingFields(modeNode, modeFields, path, mode, 0, "mode"); err != nil {
					return err
				}
				models := mappingValue(modeNode, "models")
				if models == nil || models.Kind != yaml.SequenceNode {
					continue
				}
				for modelIndex, modelNode := range models.Content {
					if err := rejectUnknownMappingFields(modelNode, modelFields, path, mode, modelIndex+1, "model"); err != nil {
						return err
					}
				}
			}
		}
	}
	return nil
}

func rejectUnknownMappingFields(node *yaml.Node, allowed map[string]bool, path, mode string, modelIndex int, scope string) error {
	if node == nil || node.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i < len(node.Content); i += 2 {
		key := node.Content[i].Value
		if !allowed[key] {
			return fmt.Errorf("config preflight %s mode %q model %d: unknown %s key %q", path, mode, modelIndex, scope, key)
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

func validateFile(file *Config) error {
	path := filePath(file)
	if file.Version != 1 {
		return preflightError(path, defaultMode, 0, "version must be 1")
	}
	if len(file.Roster) == 0 {
		return preflightError(path, defaultMode, 0, "roster must define at least one mode")
	}
	for mode, roster := range file.Roster {
		if !modeNamePattern.MatchString(mode) {
			return preflightError(path, mode, 0, "mode name must match [a-z0-9_-]+")
		}
		if len(roster.Models) == 0 {
			return preflightError(path, mode, 0, "models must be non-empty")
		}
		if err := validateModelDefinitions(file, mode, roster.Models); err != nil {
			return err
		}
	}
	if file.Defaults.Mode != "" {
		if _, ok := file.Roster[file.Defaults.Mode]; !ok {
			return preflightError(path, file.Defaults.Mode, 0, "default mode is not defined under roster")
		}
	}
	if file.Defaults.MaxRounds != nil && *file.Defaults.MaxRounds <= 0 {
		return preflightError(path, defaultMode, 0, "max_rounds must be positive")
	}
	return nil
}

func validateSlots(file *Config, mode string, slots []RosterSlot, skipStrategyPersona bool) error {
	if err := validateModelDefinitions(file, mode, slots); err != nil {
		return err
	}
	path := filePath(file)
	for i, slot := range slots {
		modelIndex := i + 1
		if !skipStrategyPersona {
			if slot.Strategy != "" && slot.Strategy != "none" {
				if err := validateStrategy(file, mode, modelIndex, slot.Strategy); err != nil {
					return err
				}
			}
			if slot.PersonaPath != "" {
				personaPath := resolveConfigRelativePath(file, slot.PersonaPath)
				if _, err := os.Stat(personaPath); err != nil {
					if os.IsNotExist(err) {
						return preflightError(path, mode, modelIndex, "persona file %q does not exist", personaPath)
					}
					return preflightError(path, mode, modelIndex, "inspect persona file %q: %v", personaPath, err)
				}
			}
		}
		if _, err := exec.LookPath(slot.Provider); err != nil {
			return preflightError(path, mode, modelIndex, "provider CLI %q is not available on PATH", slot.Provider)
		}
	}
	return nil
}

func validateModelDefinitions(file *Config, mode string, slots []RosterSlot) error {
	path := filePath(file)
	for i, slot := range slots {
		modelIndex := i + 1
		if !validProvider(slot.Provider) {
			return preflightError(path, mode, modelIndex, "unknown provider %q", slot.Provider)
		}
		if strings.TrimSpace(slot.Model) == "" {
			return preflightError(path, mode, modelIndex, "model is required")
		}
		if !validEffort(slot.Effort) {
			return preflightError(path, mode, modelIndex, "effort must be low, medium, or high")
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

func validateStrategy(file *Config, mode string, modelIndex int, strategy string) error {
	strategyPath := filepath.Join("prompts", "strategies", strategy+".md")
	if _, err := os.Stat(strategyPath); err != nil {
		if os.IsNotExist(err) {
			return preflightError(filePath(file), mode, modelIndex, "strategy file %q does not exist", strategyPath)
		}
		return preflightError(filePath(file), mode, modelIndex, "inspect strategy file %q: %v", strategyPath, err)
	}
	return nil
}

func warnDuplicates(w io.Writer, slots []RosterSlot) {
	entries := make(map[string]int)
	providerModels := make(map[string]int)
	for _, slot := range slots {
		entry := slot.Provider + "\x00" + slot.Model + "\x00" + slot.Effort + "\x00" + slot.Strategy
		entries[entry]++
		if entries[entry] == 2 {
			fmt.Fprintf(w, "warning: duplicate reviewer model (provider=%s, model=%s, effort=%s, strategy=%s)\n", slot.Provider, slot.Model, slot.Effort, slot.Strategy)
		}
		providerModel := slot.Provider + "\x00" + slot.Model
		providerModels[providerModel]++
		if providerModels[providerModel] == 11 {
			fmt.Fprintf(w, "warning: more than 10 reviewer instances for provider=%s model=%s\n", slot.Provider, slot.Model)
		}
	}
}

func resolveConfigRelativePath(file *Config, path string) string {
	if filepath.IsAbs(path) || file == nil || file.FilePath == "" {
		return path
	}
	configPath, err := filepath.Abs(file.FilePath)
	if err != nil {
		configPath = file.FilePath
	}
	return filepath.Join(filepath.Dir(configPath), path)
}

func validProvider(provider string) bool {
	switch provider {
	case "claude", "codex", "gemini":
		return true
	default:
		return false
	}
}

func validEffort(effort string) bool {
	switch effort {
	case "low", "medium", "high":
		return true
	default:
		return false
	}
}

func preflightError(path, mode string, modelIndex int, format string, args ...any) error {
	var message bytes.Buffer
	fmt.Fprintf(&message, "config preflight %s mode %q model %d: ", path, mode, modelIndex)
	fmt.Fprintf(&message, format, args...)
	return fmt.Errorf("%s", message.String())
}

package roster

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	appconfig "github.com/charlieyou/cerberus/internal/config"
	"gopkg.in/yaml.v3"
)

const defaultMode = "smart"

var builtInRoster = map[string]ModeRoster{
	"fast": {Models: []RosterSlot{
		{Provider: "claude", Model: appconfig.DefaultClaudeModel, Effort: "low"},
		{Provider: "codex", Model: appconfig.DefaultCodexModel, Effort: "low"},
		{Provider: "gemini", Model: appconfig.DefaultGeminiModel, Effort: "low"},
	}},
	"smart": {Models: []RosterSlot{
		{Provider: "claude", Model: appconfig.DefaultClaudeModel, Effort: "medium"},
		{Provider: "codex", Model: appconfig.DefaultCodexModel, Effort: "medium"},
		{Provider: "gemini", Model: appconfig.DefaultGeminiModel, Effort: "medium"},
	}},
	"max": {Models: []RosterSlot{
		{Provider: "claude", Model: appconfig.ClaudeMaxModeModel, Effort: "high"},
		{Provider: "codex", Model: appconfig.DefaultCodexModel, Effort: "high"},
		{Provider: "gemini", Model: appconfig.DefaultGeminiModel, Effort: "high"},
	}},
}

// LoadConfig loads the first applicable config.yaml. If path is empty, the
// project file wins over XDG_CONFIG_HOME and ~/.cerberus files.
func LoadConfig(path string) (*Config, error) {
	resolvedPath := path
	if resolvedPath == "" {
		found, ok, err := FindConfigFile(".")
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, nil
		}
		resolvedPath = found
	}

	file, err := os.Open(resolvedPath)
	if err != nil {
		return nil, fmt.Errorf("load config file %s: %w", resolvedPath, err)
	}
	defer file.Close()

	return decodeConfig(file, resolvedPath)
}

// FindConfigFile returns the first config.yaml according to project/user precedence.
func FindConfigFile(projectDir string) (string, bool, error) {
	projectPath := filepath.Join(projectDir, ".cerberus", "config.yaml")
	if _, err := os.Stat(projectPath); err == nil {
		return projectPath, true, nil
	} else if err != nil && !os.IsNotExist(err) {
		return "", false, fmt.Errorf("inspect project config file %s: %w", projectPath, err)
	}

	if configHome := os.Getenv("XDG_CONFIG_HOME"); configHome != "" {
		configPath := filepath.Join(configHome, "cerberus", "config.yaml")
		if _, err := os.Stat(configPath); err == nil {
			return configPath, true, nil
		} else if err != nil && !os.IsNotExist(err) {
			return "", false, fmt.Errorf("inspect user config file %s: %w", configPath, err)
		}
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return "", false, fmt.Errorf("resolve home directory: %w", err)
	}
	userPath := filepath.Join(home, ".cerberus", "config.yaml")
	if _, err := os.Stat(userPath); err == nil {
		return userPath, true, nil
	} else if err != nil && !os.IsNotExist(err) {
		return "", false, fmt.Errorf("inspect user config file %s: %w", userPath, err)
	}

	return "", false, nil
}

func decodeConfig(r io.Reader, path string) (*Config, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("read config file %s: %w", path, err)
	}
	if err := rejectUnknownFields(data, path); err != nil {
		return nil, err
	}

	var file Config
	decoder := yaml.NewDecoder(strings.NewReader(string(data)))
	decoder.KnownFields(true)
	if err := decoder.Decode(&file); err != nil {
		return nil, fmt.Errorf("config preflight %s mode %q model %d: schema parse error: %w", path, defaultMode, 0, err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return nil, fmt.Errorf("config preflight %s mode %q model %d: schema parse error: multiple YAML documents are not allowed", path, defaultMode, 0)
		}
		return nil, fmt.Errorf("config preflight %s mode %q model %d: schema parse error: %w", path, defaultMode, 0, err)
	}
	file.FilePath = path
	if err := validateFile(&file); err != nil {
		return nil, err
	}
	return &file, nil
}

// Resolve selects the model panel for one runtime mode and assigns instance IDs.
func Resolve(file *Config, mode string) ([]RosterSlot, error) {
	return ResolveWithOptions(file, ResolveOptions{Mode: mode})
}

func ResolveWithOptions(file *Config, opts ResolveOptions) ([]RosterSlot, error) {
	mode := opts.Mode
	if mode == "" && file != nil {
		mode = file.Defaults.Mode
	}
	if mode == "" {
		mode = defaultMode
	}

	var slots []RosterSlot
	if file == nil {
		selected, ok := builtInRoster[mode]
		if !ok {
			return nil, preflightError(filePath(file), mode, 0, "mode is not defined under roster")
		}
		slots = cloneSlots(selected.Models)
		slots = degradeBuiltInDefault(slots)
	} else {
		if err := validateFile(file); err != nil {
			return nil, err
		}
		selected, ok := file.Roster[mode]
		if !ok {
			return nil, preflightError(filePath(file), mode, 0, "mode is not defined under roster")
		}
		slots = cloneSlots(selected.Models)
		normalizePersonaPaths(file, slots)
	}

	if err := validateSlots(file, mode, slots, opts.SkipStrategyPersona); err != nil {
		return nil, err
	}
	assignInstanceIDs(slots)
	warnDuplicates(os.Stderr, slots)
	if err := EnforceDebateMinimum(slots, opts.Debate); err != nil {
		return nil, err
	}
	if len(slots) == 0 {
		return nil, preflightError(filePath(file), mode, 0, "empty roster after degradation")
	}
	return slots, nil
}

func assignInstanceIDs(slots []RosterSlot) {
	counts := make(map[string]int)
	for i := range slots {
		counts[slots[i].Provider]++
		slots[i].InstanceIndex = counts[slots[i].Provider]
		slots[i].InstanceID = fmt.Sprintf("%s#%d", slots[i].Provider, slots[i].InstanceIndex)
	}
}

func cloneSlots(slots []RosterSlot) []RosterSlot {
	cloned := make([]RosterSlot, len(slots))
	copy(cloned, slots)
	for i := range cloned {
		cloned[i].InstanceID = ""
		cloned[i].InstanceIndex = 0
	}
	return cloned
}

func normalizePersonaPaths(file *Config, slots []RosterSlot) {
	for i := range slots {
		if slots[i].PersonaPath != "" {
			slots[i].PersonaPath = resolveConfigRelativePath(file, slots[i].PersonaPath)
		}
	}
}

func filePath(file *Config) string {
	if file == nil || file.FilePath == "" {
		return "<built-in>"
	}
	return file.FilePath
}

package roster

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

const defaultRosterName = "default"

var builtInDefaultSlots = []RosterSlot{
	{Provider: "claude", Model: "claude"},
	{Provider: "codex", Model: "codex"},
	{Provider: "gemini", Model: "gemini"},
}

// LoadRosters loads the first applicable rosters.yaml. If path is empty, the
// project file wins over XDG_CONFIG_HOME and ~/.cerberus files.
func LoadRosters(path string) (*RostersFile, error) {
	resolvedPath := path
	if resolvedPath == "" {
		found, ok, err := FindRostersFile(".")
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
		return nil, fmt.Errorf("load rosters file %s: %w", resolvedPath, err)
	}
	defer file.Close()

	return decodeRosters(file, resolvedPath)
}

// FindRostersFile returns the first rosters.yaml according to project/user precedence.
func FindRostersFile(projectDir string) (string, bool, error) {
	projectPath := filepath.Join(projectDir, ".cerberus", "rosters.yaml")
	if _, err := os.Stat(projectPath); err == nil {
		return projectPath, true, nil
	} else if err != nil && !os.IsNotExist(err) {
		return "", false, fmt.Errorf("inspect project rosters file %s: %w", projectPath, err)
	}

	if configHome := os.Getenv("XDG_CONFIG_HOME"); configHome != "" {
		configPath := filepath.Join(configHome, "cerberus", "rosters.yaml")
		if _, err := os.Stat(configPath); err == nil {
			return configPath, true, nil
		} else if err != nil && !os.IsNotExist(err) {
			return "", false, fmt.Errorf("inspect user rosters file %s: %w", configPath, err)
		}
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return "", false, fmt.Errorf("resolve home directory: %w", err)
	}
	userPath := filepath.Join(home, ".cerberus", "rosters.yaml")
	if _, err := os.Stat(userPath); err == nil {
		return userPath, true, nil
	} else if err != nil && !os.IsNotExist(err) {
		return "", false, fmt.Errorf("inspect user rosters file %s: %w", userPath, err)
	}

	return "", false, nil
}

func decodeRosters(r io.Reader, path string) (*RostersFile, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("read rosters file %s: %w", path, err)
	}
	if err := rejectUnknownFields(data, path); err != nil {
		return nil, err
	}

	var file RostersFile
	decoder := yaml.NewDecoder(strings.NewReader(string(data)))
	decoder.KnownFields(true)
	if err := decoder.Decode(&file); err != nil {
		return nil, fmt.Errorf("roster preflight %s roster %q slot %d: schema parse error: %w", path, defaultRosterName, 0, err)
	}
	file.FilePath = path
	return &file, nil
}

// Resolve applies file/built-in selection, CLI append/replace, and instance IDs.
func Resolve(file *RostersFile, name string, cliReviewers []string, replaceSlot string) ([]RosterSlot, error) {
	return ResolveWithOptions(file, ResolveOptions{
		RosterName:   name,
		CLIReviewers: cliReviewers,
		ReplaceSlot:  replaceSlot,
	})
}

// ResolveWithOptions is Resolve plus preflight-only checks for debate and legacy agents.
func ResolveWithOptions(file *RostersFile, opts ResolveOptions) ([]RosterSlot, error) {
	rosterName := opts.RosterName
	if rosterName == "" {
		rosterName = defaultRosterName
	}
	if opts.Agents != "" && (opts.RosterName != "" || len(opts.CLIReviewers) > 0) {
		return nil, preflightError(filePath(file), rosterName, 0, "--agents is mutually exclusive with --roster and --reviewer")
	}

	var slots []RosterSlot
	builtIn := file == nil
	if builtIn {
		slots = cloneSlots(builtInDefaultSlots)
		slots = degradeBuiltInDefault(slots)
	} else {
		if err := validateFile(file); err != nil {
			return nil, err
		}
		selected, ok := file.Rosters[rosterName]
		if !ok {
			if opts.RosterName == "" {
				return nil, fmt.Errorf("roster preflight %s roster %q slot %d: no roster named %q in %s; pass --roster <name> to select an existing roster, or remove rosters.yaml to use the built-in default", filePath(file), rosterName, 0, rosterName, filePath(file))
			}
			return nil, preflightError(filePath(file), rosterName, 0, "no roster named %q", rosterName)
		}
		slots = cloneSlots(selected.Reviewers)
	}

	if err := validateSlots(file, rosterName, slots); err != nil {
		return nil, err
	}
	assignInstanceIDs(slots)

	if opts.ReplaceSlot != "" {
		if len(opts.CLIReviewers) != 1 {
			return nil, preflightError(filePath(file), rosterName, 0, "--replace-slot requires exactly one --reviewer")
		}
		replacement, err := parseCLIReviewer(opts.CLIReviewers[0], filePath(file), rosterName)
		if err != nil {
			return nil, err
		}
		index := -1
		for i := range slots {
			if slots[i].InstanceID == opts.ReplaceSlot {
				index = i
				break
			}
		}
		if index == -1 {
			return nil, preflightError(filePath(file), rosterName, 0, "--replace-slot %q references a non-existent slot", opts.ReplaceSlot)
		}
		slots[index] = replacement
	} else {
		for _, reviewer := range opts.CLIReviewers {
			slot, err := parseCLIReviewer(reviewer, filePath(file), rosterName)
			if err != nil {
				return nil, err
			}
			slots = append(slots, slot)
		}
	}

	if err := validateSlots(file, rosterName, slots); err != nil {
		return nil, err
	}
	assignInstanceIDs(slots)
	warnDuplicates(os.Stderr, slots)
	if len(slots) == 0 {
		return nil, preflightError(filePath(file), rosterName, 0, "resulting panel is empty")
	}
	if opts.Debate && len(slots) == 1 {
		return nil, preflightError(filePath(file), rosterName, 1, "1-reviewer panel is not valid with --debate")
	}
	return slots, nil
}

func parseCLIReviewer(value, path, rosterName string) (RosterSlot, error) {
	parts := strings.Split(value, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return RosterSlot{}, preflightError(path, rosterName, 0, "--reviewer must use provider:model[:strategy]")
	}
	for _, part := range parts {
		if part == "" {
			return RosterSlot{}, preflightError(path, rosterName, 0, "--reviewer must use provider:model[:strategy]")
		}
	}
	slot := RosterSlot{Provider: parts[0], Model: parts[1]}
	if len(parts) == 3 {
		slot.Strategy = parts[2]
	}
	return slot, nil
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

func filePath(file *RostersFile) string {
	if file == nil || file.FilePath == "" {
		return "<built-in>"
	}
	return file.FilePath
}

package roster

// RosterSlot is one reviewer slot in a resolved panel.
type RosterSlot struct {
	Provider      string `yaml:"provider"`
	Model         string `yaml:"model"`
	Effort        string `yaml:"effort"`
	Strategy      string `yaml:"strategy,omitempty"`
	PersonaPath   string `yaml:"persona,omitempty"`
	InstanceID    string `yaml:"-"`
	InstanceIndex int    `yaml:"-"`
}

// ModeRoster is the model panel for one runtime mode.
type ModeRoster struct {
	Models []RosterSlot `yaml:"models"`
}

// Defaults contains optional runtime defaults.
type Defaults struct {
	Mode      string `yaml:"mode,omitempty"`
	MaxRounds *int   `yaml:"max_rounds,omitempty"`
}

// Config is the top-level config.yaml schema.
type Config struct {
	Version  int                   `yaml:"version"`
	Defaults Defaults              `yaml:"defaults,omitempty"`
	Roster   map[string]ModeRoster `yaml:"roster"`
	FilePath string                `yaml:"-"`
}

// ResolveOptions carries preflight-only inputs not present in the minimal
// Resolve signature used by the CLI merge flow.
type ResolveOptions struct {
	Mode   string
	Debate bool
	// SkipStrategyPersona omits validation of review-only slot fields (strategy
	// prompt files and persona files). Generator panels copy only
	// provider/model/label and never use these, so requiring those files would
	// fail generation spuriously.
	SkipStrategyPersona bool
}

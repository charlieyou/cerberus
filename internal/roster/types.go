package roster

// RosterSlot is one reviewer slot in a resolved panel.
type RosterSlot struct {
	Provider      string `yaml:"provider"`
	Model         string `yaml:"model"`
	Strategy      string `yaml:"strategy,omitempty"`
	PersonaPath   string `yaml:"persona,omitempty"`
	Mode          string `yaml:"mode,omitempty"`
	InstanceID    string `yaml:"-"`
	InstanceIndex int    `yaml:"-"`
}

// Roster is a named YAML roster definition.
type Roster struct {
	Reviewers []RosterSlot `yaml:"reviewers"`
}

// RosterDefaults contains optional panel-wide YAML defaults.
type RosterDefaults struct {
	Mode      string `yaml:"mode,omitempty"`
	MaxRounds *int   `yaml:"max_rounds,omitempty"`
}

// RostersFile is the top-level YAML schema.
type RostersFile struct {
	Version  int               `yaml:"version"`
	Defaults RosterDefaults    `yaml:"defaults,omitempty"`
	Rosters  map[string]Roster `yaml:"rosters"`
	FilePath string            `yaml:"-"`
	BuiltIn  bool              `yaml:"-"`
}

// ResolveOptions carries preflight-only inputs not present in the minimal
// Resolve signature used by the CLI merge flow.
type ResolveOptions struct {
	RosterName   string
	CLIReviewers []string
	ReplaceSlot  string
	Debate       bool
	Agents       string
	// SkipStrategyPersona omits validation of review-only slot fields (strategy
	// prompt files and persona files). Generator panels copy only
	// provider/model/label and never use these, so requiring those files would
	// fail generation spuriously.
	SkipStrategyPersona bool
}

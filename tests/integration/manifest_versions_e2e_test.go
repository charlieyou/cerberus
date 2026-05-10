package integration_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

const gaPluginVersion = "2.0.0"

func TestManifestVersionsE2E(t *testing.T) {
	repoRoot := manifestVersionsE2ERepoRoot(t)

	tests := []struct {
		name string
		path string
		want any
	}{
		{
			name: "claude",
			path: filepath.Join(repoRoot, ".claude-plugin", "plugin.json"),
			want: claudePluginManifest{
				Name:        "cerberus",
				Version:     gaPluginVersion,
				Description: "Three-headed guardian of code quality. Multi-model consensus review with Codex, Gemini, and Claude.",
				Author: pluginManifestAuthor{
					Name: "charlieyou",
				},
				Repository: "https://github.com/charlieyou/cerberus",
				License:    "MIT",
				Skills:     "./skills/",
				Keywords:   expectedPluginKeywords(),
			},
		},
		{
			name: "codex",
			path: filepath.Join(repoRoot, ".codex-plugin", "plugin.json"),
			want: codexPluginManifest{
				Name:        "cerberus",
				Version:     gaPluginVersion,
				Description: "Three-headed guardian of code quality. Multi-model consensus review with Codex, Gemini, and Claude.",
				Author: pluginManifestAuthor{
					Name: "charlieyou",
				},
				Repository: "https://github.com/charlieyou/cerberus",
				License:    "MIT",
				Keywords:   expectedPluginKeywords(),
				Skills:     "./skills/",
				Hooks:      "./hooks/codex-hooks.json",
				Interface: codexPluginInterface{
					DisplayName:      "Cerberus",
					ShortDescription: "Multi-model review gates for Codex",
					LongDescription:  "Run Codex, Gemini, and Claude review panels for code, plans, specs, and open-ended design questions, then gate session stop until consensus is reached.",
					DeveloperName:    "charlieyou",
					Category:         "Coding",
					Capabilities:     []string{"Interactive", "Read", "Write"},
					WebsiteURL:       "https://github.com/charlieyou/cerberus",
					DefaultPrompt: []string{
						"Review this change with Cerberus",
						"Ask the Cerberus panel for a second opinion",
						"Check the current Cerberus gate status",
					},
					BrandColor: "#111827",
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := newManifestOfSameType(t, tt.want)
			decodeStrictJSONFile(t, tt.path, got)
			gotValue := reflect.ValueOf(got).Elem().Interface()
			if !reflect.DeepEqual(gotValue, tt.want) {
				t.Fatalf("%s manifest drifted\nwant: %#v\n got: %#v", tt.path, tt.want, gotValue)
			}
			version := manifestVersion(t, got)
			if version != gaPluginVersion {
				t.Fatalf("%s version = %q, want %s", tt.path, version, gaPluginVersion)
			}
		})
	}
}

func TestClaudeMarketplaceVersionsE2E(t *testing.T) {
	repoRoot := manifestVersionsE2ERepoRoot(t)
	path := filepath.Join(repoRoot, ".claude-plugin", "marketplace.json")

	var marketplace claudePluginMarketplace
	decodeStrictJSONFile(t, path, &marketplace)

	v2Entry := findMarketplaceEntry(marketplace.Plugins, gaPluginVersion)
	if v2Entry == nil {
		t.Fatalf("%s missing cerberus marketplace entry for version %s", path, gaPluginVersion)
	}
	if got, want := v2Entry.Source.String, "./"; got != want {
		t.Fatalf("%s version %s source = %q, want %q", path, gaPluginVersion, got, want)
	}

	v1Entry := findV154MarketplaceEntry(marketplace.Plugins)
	if v1Entry == nil {
		t.Fatalf("%s missing cerberus marketplace rollback entry for version 1.54.x", path)
	}
	if v1Entry.Source.Git == nil {
		t.Fatalf("%s version %s source must be a git source object", path, v1Entry.Version)
	}
	if v1Entry.Source.Git.Source != "url" {
		t.Fatalf("%s version %s source.source = %q, want url", path, v1Entry.Version, v1Entry.Source.Git.Source)
	}
	if v1Entry.Source.Git.URL != "https://github.com/charlieyou/cerberus.git" {
		t.Fatalf("%s version %s source.url = %q, want https://github.com/charlieyou/cerberus.git", path, v1Entry.Version, v1Entry.Source.Git.URL)
	}
	if wantRef := "v" + v1Entry.Version; v1Entry.Source.Git.Ref != wantRef {
		t.Fatalf("%s version %s source.ref = %q, want %q", path, v1Entry.Version, v1Entry.Source.Git.Ref, wantRef)
	}
}

type claudePluginManifest struct {
	Name        string               `json:"name"`
	Version     string               `json:"version"`
	Description string               `json:"description"`
	Author      pluginManifestAuthor `json:"author"`
	Repository  string               `json:"repository"`
	License     string               `json:"license"`
	Skills      string               `json:"skills"`
	Keywords    []string             `json:"keywords"`
}

type codexPluginManifest struct {
	Name        string               `json:"name"`
	Version     string               `json:"version"`
	Description string               `json:"description"`
	Author      pluginManifestAuthor `json:"author"`
	Repository  string               `json:"repository"`
	License     string               `json:"license"`
	Keywords    []string             `json:"keywords"`
	Skills      string               `json:"skills"`
	Hooks       string               `json:"hooks"`
	Interface   codexPluginInterface `json:"interface"`
}

type pluginManifestAuthor struct {
	Name string `json:"name"`
}

type codexPluginInterface struct {
	DisplayName      string   `json:"displayName"`
	ShortDescription string   `json:"shortDescription"`
	LongDescription  string   `json:"longDescription"`
	DeveloperName    string   `json:"developerName"`
	Category         string   `json:"category"`
	Capabilities     []string `json:"capabilities"`
	WebsiteURL       string   `json:"websiteURL"`
	DefaultPrompt    []string `json:"defaultPrompt"`
	BrandColor       string   `json:"brandColor"`
}

type claudePluginMarketplace struct {
	Name    string                   `json:"name"`
	Owner   pluginManifestAuthor     `json:"owner"`
	Plugins []claudeMarketplaceEntry `json:"plugins"`
}

type claudeMarketplaceEntry struct {
	Name    string            `json:"name"`
	Version string            `json:"version"`
	Source  marketplaceSource `json:"source"`
}

type marketplaceSource struct {
	String string
	Git    *marketplaceGitSource
}

type marketplaceGitSource struct {
	Source string `json:"source"`
	URL    string `json:"url"`
	Ref    string `json:"ref"`
}

func (s *marketplaceSource) UnmarshalJSON(data []byte) error {
	var sourceString string
	if err := json.Unmarshal(data, &sourceString); err == nil {
		s.String = sourceString
		s.Git = nil
		return nil
	}

	var git marketplaceGitSource
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&git); err != nil {
		return fmt.Errorf("marketplace source must be a string or git object: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return fmt.Errorf("marketplace source contains trailing JSON")
	}
	s.String = ""
	s.Git = &git
	return nil
}

func decodeStrictJSONFile(t *testing.T, path string, out any) {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile(%s) error = %v", path, err)
	}

	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(out); err != nil {
		t.Fatalf("Decode(%s) error = %v", path, err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		t.Fatalf("Decode(%s) found trailing JSON", path)
	}
}

func newManifestOfSameType(t *testing.T, manifest any) any {
	t.Helper()

	switch manifest.(type) {
	case claudePluginManifest:
		return &claudePluginManifest{}
	case codexPluginManifest:
		return &codexPluginManifest{}
	default:
		t.Fatalf("unsupported manifest type %T", manifest)
	}
	return nil
}

func manifestVersion(t *testing.T, manifest any) string {
	t.Helper()

	switch m := manifest.(type) {
	case *claudePluginManifest:
		return m.Version
	case *codexPluginManifest:
		return m.Version
	default:
		t.Fatalf("unsupported manifest type %T", manifest)
	}
	return ""
}

func expectedPluginKeywords() []string {
	return []string{
		"code-review",
		"plan-review",
		"multi-model",
		"quality-gate",
		"cerberus",
	}
}

func findMarketplaceEntry(entries []claudeMarketplaceEntry, version string) *claudeMarketplaceEntry {
	for i := range entries {
		if entries[i].Name == "cerberus" && entries[i].Version == version {
			return &entries[i]
		}
	}
	return nil
}

func findV154MarketplaceEntry(entries []claudeMarketplaceEntry) *claudeMarketplaceEntry {
	for i := range entries {
		version := entries[i].Version
		if entries[i].Name == "cerberus" && (version == "1.54.x" || strings.HasPrefix(version, "1.54.")) {
			return &entries[i]
		}
	}
	return nil
}

func manifestVersionsE2ERepoRoot(t *testing.T) string {
	t.Helper()

	_, path, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(path), "..", ".."))
}

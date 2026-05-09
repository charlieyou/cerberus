package anonymize

import (
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

var (
	selfRefRe             = regexp.MustCompile(`(?i)\b(as the|I|my|as)[,\s]+(?:the\s+)?(?:claude|codex|gemini)(_|[^[:alnum:]_-]|$)`)
	selfRefCommaCleanupRe = regexp.MustCompile(`(?i)\b(I|my) (peer_[0-9]+),`)
	providerRe            = regexp.MustCompile(`(?i)(claude|codex|gemini)([_-]|[^[:alnum:]_-]|$)`)
	modelRe               = regexp.MustCompile(`(?i)\b(claude-opus[a-z0-9.-]*|gpt-[0-9.a-z]+|gemini-[0-9.a-z-]+)\b`)
)

func Scrub(text string, peerID string, rosterModelNames []string) string {
	return newScrubber(rosterModelNames).Scrub(text, peerID)
}

type scrubber struct {
	rosterModelNames []string
}

func newScrubber(rosterModelNames []string) scrubber {
	models := make([]string, 0, len(rosterModelNames))
	seen := make(map[string]bool, len(rosterModelNames))
	for _, model := range rosterModelNames {
		if model == "" {
			continue
		}
		key := strings.ToLower(model)
		if seen[key] {
			continue
		}
		seen[key] = true
		models = append(models, model)
	}
	sort.SliceStable(models, func(i, j int) bool {
		return len(models[i]) > len(models[j])
	})
	return scrubber{rosterModelNames: models}
}

func (s scrubber) Scrub(text string, peerID string) string {
	scrubbed := selfRefRe.ReplaceAllString(text, "${1} "+peerID+"${2}")
	scrubbed = selfRefCommaCleanupRe.ReplaceAllString(scrubbed, "${1} ${2}")
	for _, model := range s.rosterModelNames {
		scrubbed = replaceLiteralFold(scrubbed, model, "peer-model")
	}
	scrubbed = modelRe.ReplaceAllString(scrubbed, "peer-model")
	return providerRe.ReplaceAllString(scrubbed, "peer${2}")
}

func replaceLiteralFold(text, old, replacement string) string {
	if old == "" {
		return text
	}

	var out strings.Builder
	for i := 0; i < len(text); {
		if hasLiteralFoldPrefix(text[i:], old) {
			out.WriteString(replacement)
			i += len(old)
			continue
		}
		_, size := utf8.DecodeRuneInString(text[i:])
		out.WriteString(text[i : i+size])
		i += size
	}
	return out.String()
}

func hasLiteralFoldPrefix(text string, old string) bool {
	if len(text) < len(old) {
		return false
	}
	candidate := text[:len(old)]
	return utf8.ValidString(candidate) && strings.EqualFold(candidate, old)
}

package anonymize

import (
	"regexp"
)

var (
	selfRefRe             = regexp.MustCompile(`(?i)\b(as the|I|my|as)[,\s]+(?:the\s+)?(?:claude|codex|gemini)\b`)
	selfRefCommaCleanupRe = regexp.MustCompile(`(?i)\b(I|my) (peer_[0-9]+),`)
	providerRe            = regexp.MustCompile(`(?i)(claude|codex|gemini)(_|[^[:alnum:]_-]|$)`)
	modelRe               = regexp.MustCompile(`(?i)\b(claude-opus[a-z0-9.-]*|gpt-[0-9.a-z]+|gemini-[0-9.a-z-]+)\b`)
)

func Scrub(text string, peerID string, rosterModelNames []string) string {
	scrubbed := selfRefRe.ReplaceAllString(text, "${1} "+peerID)
	scrubbed = selfRefCommaCleanupRe.ReplaceAllString(scrubbed, "${1} ${2}")
	scrubbed = providerRe.ReplaceAllString(scrubbed, "peer${2}")
	for _, model := range rosterModelNames {
		if model == "" {
			continue
		}
		scrubbed = replaceLiteralFold(scrubbed, model, "peer-model")
	}
	return modelRe.ReplaceAllString(scrubbed, "peer-model")
}

func replaceLiteralFold(text, old, replacement string) string {
	re := regexp.MustCompile(`(?i)` + regexp.QuoteMeta(old))
	return re.ReplaceAllString(text, replacement)
}

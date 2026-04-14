export type IntelligenceMode = 'fast' | 'smart' | 'max'

export type ResolvedModels = {
	mode: IntelligenceMode
	codexModel: string
	codexReasoningEffort: string
	geminiModel: string
	claudeModel: string
	ultrathink: boolean
}

const MODE_DEFAULTS: Record<IntelligenceMode, { codexEffort: string; gemini: string; claude: string; ultrathink: boolean }> = {
	fast: { codexEffort: 'medium', gemini: 'gemini-3-flash-preview', claude: 'sonnet', ultrathink: false },
	smart: { codexEffort: 'high', gemini: 'gemini-3.1-pro-preview', claude: 'opus', ultrathink: false },
	max: { codexEffort: 'xhigh', gemini: 'gemini-3.1-pro-preview', claude: 'opus', ultrathink: true },
}

const VALID_MODES = new Set<string>(['fast', 'smart', 'max'])

export function normalizeMode(value: string | undefined): IntelligenceMode {
	if (!value) return 'smart'
	const lower = value.toLowerCase()
	if (VALID_MODES.has(lower)) return lower as IntelligenceMode
	return 'smart'
}

export function resolveModels(
	mode?: string,
	env: Record<string, string | undefined> = process.env as Record<string, string | undefined>,
): ResolvedModels {
	const resolved = normalizeMode(mode)
	const defaults = MODE_DEFAULTS[resolved]

	return {
		mode: resolved,
		codexModel: env.CODEX_MODEL_OVERRIDE ?? env.CODEX_MODEL ?? 'gpt-5.4',
		codexReasoningEffort: env.CODEX_REASONING_EFFORT_OVERRIDE ?? defaults.codexEffort,
		geminiModel: env.GEMINI_MODEL_OVERRIDE ?? env.GEMINI_MODEL ?? defaults.gemini,
		claudeModel: env.CLAUDE_MODEL_OVERRIDE ?? env.CLAUDE_MODEL ?? defaults.claude,
		ultrathink: defaults.ultrathink,
	}
}

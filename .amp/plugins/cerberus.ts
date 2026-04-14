// @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now
import type { PluginAPI } from '@ampcode/plugin'
import { readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'

const PLUGIN_ROOT = resolve(import.meta.dir, '..', '..')
const PROMPTS_DIR = join(PLUGIN_ROOT, 'prompts')
const STATE_DIR = join(PLUGIN_ROOT, '.tmp', 'cerberus')

export function getPluginRoot() {
	return PLUGIN_ROOT
}

export function getPromptsDir() {
	return PROMPTS_DIR
}

export function getStateDir() {
	return STATE_DIR
}

export async function loadPrompt(relativePath: string): Promise<string> {
	const fullPath = join(PROMPTS_DIR, relativePath)
	return readFile(fullPath, 'utf8')
}

export function resolveThreadStateDir(threadId: string): string {
	return join(STATE_DIR, sanitizeId(threadId))
}

function sanitizeId(id: string): string {
	return id.replace(/[^a-zA-Z0-9._-]/g, '_')
}

export default function cerberus(amp: PluginAPI) {
	amp.on('session.start', async (_event, _ctx) => {})
}

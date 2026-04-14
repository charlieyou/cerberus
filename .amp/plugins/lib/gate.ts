import { mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { resolveThreadStateDir } from '../cerberus'

export type GateStatus = 'pending' | 'awaiting_decision' | 'resolved'

export type ReviewerState = {
	outputFile: string
	sentinelFile: string
	completedAt: string | null
	result: unknown | null
}

export type ConsensusResult = {
	verdict: string
	iteration: number
}

export type GateDecision = {
	action: string
	decidedAt: string
	reason: string
}

export type GateState = {
	version: number
	status: GateStatus
	triggerSource: string
	reviewers: Record<string, ReviewerState>
	consensus: ConsensusResult | null
	decision: GateDecision | null
	iteration: number
	createdAt: string
	updatedAt: string
	lastTurnId: string | null
}

const GATE_STATE_FILE = 'gate-state.json'
const ACTIVE_GATE_FILE = 'active-gate'
const LOCK_FILE = 'gate.lock'
const LOCK_STALE_MS = 30_000

export function gateStatePath(threadId: string): string {
	return join(resolveThreadStateDir(threadId), GATE_STATE_FILE)
}

function activeGatePath(threadId: string): string {
	return join(resolveThreadStateDir(threadId), ACTIVE_GATE_FILE)
}

function lockPath(threadId: string, gateId: string): string {
	return join(resolveThreadStateDir(threadId), gateId, LOCK_FILE)
}

function gateDir(threadId: string, gateId: string): string {
	return join(resolveThreadStateDir(threadId), gateId)
}

function gateStateFile(threadId: string, gateId: string): string {
	return join(gateDir(threadId, gateId), GATE_STATE_FILE)
}

export function createGateState(overrides: Partial<GateState> = {}): GateState {
	const now = new Date().toISOString()
	return {
		version: 1,
		status: 'pending',
		triggerSource: 'plugin',
		reviewers: {},
		consensus: null,
		decision: null,
		iteration: 0,
		createdAt: now,
		updatedAt: now,
		lastTurnId: null,
		...overrides,
	}
}

export async function saveGateState(
	threadId: string,
	gateId: string,
	state: GateState,
): Promise<void> {
	const dir = gateDir(threadId, gateId)
	await mkdir(dir, { recursive: true })
	const updated = { ...state, updatedAt: new Date().toISOString() }
	await writeFile(gateStateFile(threadId, gateId), `${JSON.stringify(updated, null, 2)}\n`, 'utf8')
}

export async function loadGateState(
	threadId: string,
	gateId: string,
): Promise<GateState | null> {
	try {
		const raw = await readFile(gateStateFile(threadId, gateId), 'utf8')
		return JSON.parse(raw) as GateState
	} catch {
		return null
	}
}

export async function setActiveGate(threadId: string, gateId: string): Promise<void> {
	const dir = resolveThreadStateDir(threadId)
	await mkdir(dir, { recursive: true })
	await writeFile(activeGatePath(threadId), gateId, 'utf8')
}

export async function getActiveGate(threadId: string): Promise<string | null> {
	try {
		const id = await readFile(activeGatePath(threadId), 'utf8')
		return id.trim() || null
	} catch {
		return null
	}
}

export async function clearActiveGate(threadId: string): Promise<void> {
	await rm(activeGatePath(threadId), { force: true })
}

export async function loadActiveGateState(threadId: string): Promise<{ gateId: string; state: GateState } | null> {
	const gateId = await getActiveGate(threadId)
	if (!gateId) return null
	const state = await loadGateState(threadId, gateId)
	if (!state) return null
	return { gateId, state }
}

type LockInfo = {
	pid: number
	acquiredAt: number
}

export class GateLock {
	private threadId: string
	private gateId: string
	private acquired = false

	constructor(threadId: string, gateId: string) {
		this.threadId = threadId
		this.gateId = gateId
	}

	async acquire(): Promise<boolean> {
		const path = lockPath(this.threadId, this.gateId)
		const dir = gateDir(this.threadId, this.gateId)
		await mkdir(dir, { recursive: true })

		const existing = await this.readLock()
		if (existing) {
			const age = Date.now() - existing.acquiredAt
			if (age < LOCK_STALE_MS) {
				return false
			}
		}

		const info: LockInfo = { pid: process.pid, acquiredAt: Date.now() }
		await writeFile(path, JSON.stringify(info), 'utf8')

		const verify = await this.readLock()
		if (verify?.pid !== process.pid) {
			return false
		}

		this.acquired = true
		return true
	}

	async release(): Promise<void> {
		if (!this.acquired) return
		await rm(lockPath(this.threadId, this.gateId), { force: true })
		this.acquired = false
	}

	private async readLock(): Promise<LockInfo | null> {
		try {
			const raw = await readFile(lockPath(this.threadId, this.gateId), 'utf8')
			return JSON.parse(raw) as LockInfo
		} catch {
			return null
		}
	}
}

export async function withGateLock<T>(
	threadId: string,
	gateId: string,
	fn: () => Promise<T>,
): Promise<T> {
	const lock = new GateLock(threadId, gateId)
	if (!(await lock.acquire())) {
		throw new Error(`Failed to acquire gate lock for thread=${threadId} gate=${gateId}`)
	}
	try {
		return await fn()
	} finally {
		await lock.release()
	}
}

import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { rm } from 'node:fs/promises'
import { join } from 'node:path'
import { getStateDir } from '../cerberus'
import {
	GateLock,
	clearActiveGate,
	createGateState,
	getActiveGate,
	loadActiveGateState,
	loadGateState,
	saveGateState,
	setActiveGate,
	withGateLock,
} from './gate'

const TEST_THREAD = 'test-thread-gate-001'
const TEST_GATE = 'gate-abc123'

beforeEach(async () => {
	await rm(join(getStateDir(), TEST_THREAD), { recursive: true, force: true })
})

afterEach(async () => {
	await rm(join(getStateDir(), TEST_THREAD), { recursive: true, force: true })
})

describe('gate state read/write', () => {
	test('createGateState returns defaults', () => {
		const state = createGateState()
		expect(state.version).toBe(1)
		expect(state.status).toBe('pending')
		expect(state.iteration).toBe(0)
		expect(state.reviewers).toEqual({})
		expect(state.consensus).toBeNull()
		expect(state.decision).toBeNull()
		expect(state.lastTurnId).toBeNull()
	})

	test('createGateState accepts overrides', () => {
		const state = createGateState({ status: 'resolved', iteration: 3 })
		expect(state.status).toBe('resolved')
		expect(state.iteration).toBe(3)
	})

	test('save and load gate state round-trips', async () => {
		const state = createGateState({ triggerSource: 'test' })
		await saveGateState(TEST_THREAD, TEST_GATE, state)
		const loaded = await loadGateState(TEST_THREAD, TEST_GATE)
		expect(loaded).not.toBeNull()
		expect(loaded!.triggerSource).toBe('test')
		expect(loaded!.status).toBe('pending')
		expect(loaded!.version).toBe(1)
	})

	test('load returns null for missing gate', async () => {
		const loaded = await loadGateState(TEST_THREAD, 'nonexistent')
		expect(loaded).toBeNull()
	})

	test('save updates updatedAt timestamp', async () => {
		const state = createGateState()
		const originalUpdated = state.updatedAt
		await new Promise((r) => setTimeout(r, 10))
		await saveGateState(TEST_THREAD, TEST_GATE, state)
		const loaded = await loadGateState(TEST_THREAD, TEST_GATE)
		expect(loaded!.updatedAt).not.toBe(originalUpdated)
	})

	test('state stores reviewers, consensus, and decision', async () => {
		const state = createGateState({
			reviewers: {
				claude: {
					outputFile: '/tmp/claude.json',
					sentinelFile: '/tmp/claude.done',
					completedAt: null,
					result: null,
				},
			},
			consensus: { verdict: 'PASS', iteration: 1 },
			decision: { action: 'proceed', decidedAt: new Date().toISOString(), reason: 'all_pass' },
			lastTurnId: 'turn-xyz',
		})
		await saveGateState(TEST_THREAD, TEST_GATE, state)
		const loaded = await loadGateState(TEST_THREAD, TEST_GATE)
		expect(loaded!.reviewers.claude.outputFile).toBe('/tmp/claude.json')
		expect(loaded!.consensus!.verdict).toBe('PASS')
		expect(loaded!.decision!.reason).toBe('all_pass')
		expect(loaded!.lastTurnId).toBe('turn-xyz')
	})
})

describe('active gate tracking', () => {
	test('set and get active gate', async () => {
		await setActiveGate(TEST_THREAD, TEST_GATE)
		const active = await getActiveGate(TEST_THREAD)
		expect(active).toBe(TEST_GATE)
	})

	test('get returns null when no active gate', async () => {
		const active = await getActiveGate(TEST_THREAD)
		expect(active).toBeNull()
	})

	test('clear active gate', async () => {
		await setActiveGate(TEST_THREAD, TEST_GATE)
		await clearActiveGate(TEST_THREAD)
		const active = await getActiveGate(TEST_THREAD)
		expect(active).toBeNull()
	})

	test('loadActiveGateState returns combined result', async () => {
		const state = createGateState({ triggerSource: 'active-test' })
		await saveGateState(TEST_THREAD, TEST_GATE, state)
		await setActiveGate(TEST_THREAD, TEST_GATE)
		const result = await loadActiveGateState(TEST_THREAD)
		expect(result).not.toBeNull()
		expect(result!.gateId).toBe(TEST_GATE)
		expect(result!.state.triggerSource).toBe('active-test')
	})

	test('loadActiveGateState returns null when no active gate', async () => {
		const result = await loadActiveGateState(TEST_THREAD)
		expect(result).toBeNull()
	})
})

describe('gate locking', () => {
	test('acquire and release lock', async () => {
		const lock = new GateLock(TEST_THREAD, TEST_GATE)
		const acquired = await lock.acquire()
		expect(acquired).toBe(true)
		await lock.release()
	})

	test('second acquire fails while lock held', async () => {
		const lock1 = new GateLock(TEST_THREAD, TEST_GATE)
		const lock2 = new GateLock(TEST_THREAD, TEST_GATE)
		await lock1.acquire()
		const acquired = await lock2.acquire()
		expect(acquired).toBe(false)
		await lock1.release()
	})

	test('acquire succeeds after release', async () => {
		const lock1 = new GateLock(TEST_THREAD, TEST_GATE)
		await lock1.acquire()
		await lock1.release()
		const lock2 = new GateLock(TEST_THREAD, TEST_GATE)
		const acquired = await lock2.acquire()
		expect(acquired).toBe(true)
		await lock2.release()
	})

	test('release is idempotent', async () => {
		const lock = new GateLock(TEST_THREAD, TEST_GATE)
		await lock.acquire()
		await lock.release()
		await lock.release()
	})

	test('withGateLock runs fn and releases', async () => {
		let ran = false
		await withGateLock(TEST_THREAD, TEST_GATE, async () => {
			ran = true
		})
		expect(ran).toBe(true)

		const lock = new GateLock(TEST_THREAD, TEST_GATE)
		const acquired = await lock.acquire()
		expect(acquired).toBe(true)
		await lock.release()
	})

	test('withGateLock releases on error', async () => {
		try {
			await withGateLock(TEST_THREAD, TEST_GATE, async () => {
				throw new Error('test error')
			})
		} catch {
			// expected
		}

		const lock = new GateLock(TEST_THREAD, TEST_GATE)
		const acquired = await lock.acquire()
		expect(acquired).toBe(true)
		await lock.release()
	})

	test('withGateLock throws when lock unavailable', async () => {
		const lock = new GateLock(TEST_THREAD, TEST_GATE)
		await lock.acquire()

		expect(
			withGateLock(TEST_THREAD, TEST_GATE, async () => {}),
		).rejects.toThrow('Failed to acquire gate lock')

		await lock.release()
	})
})

import { describe, expect, it } from 'vitest'
import { parseHostStatus, sameHostStatus, statusView, type HostStatus, type SyncStatus } from '../status'

const shown = (kind: string, online: boolean, sync: SyncStatus, host: HostStatus | null = null) =>
  statusView({ kind, online, sync, host })

describe('parseHostStatus', () => {
  it('takes a value or JSON, and drops a zero or fractional pending', () => {
    expect(parseHostStatus({ mode: 'shared-live' })).toEqual({ mode: 'shared-live' })
    expect(parseHostStatus('{"mode":"shared-offline","pending":3}')).toEqual({ mode: 'shared-offline', pending: 3 })
    expect(parseHostStatus({ mode: 'shared-offline', pending: 0 })).toEqual({ mode: 'shared-offline' })
    expect(parseHostStatus({ mode: 'shared-offline', pending: 2.7 })).toEqual({ mode: 'shared-offline', pending: 2 })
  })

  it('clears on null, an empty string or a null mode', () => {
    expect(parseHostStatus(null)).toBeNull()
    expect(parseHostStatus('')).toBeNull()
    expect(parseHostStatus('null')).toBeNull()
    expect(parseHostStatus({ mode: null })).toBeNull()
  })

  it('refuses unknown modes and bad counts', () => {
    expect(() => parseHostStatus({ mode: 'online' })).toThrow(/mode/)
    expect(() => parseHostStatus({ mode: 'shared-offline', pending: -1 })).toThrow(/pending/)
    expect(() => parseHostStatus(['shared-live'])).toThrow()
  })

  it('compares by value', () => {
    expect(sameHostStatus({ mode: 'local' }, { mode: 'local' })).toBe(true)
    expect(sameHostStatus({ mode: 'shared-offline' }, { mode: 'shared-offline', pending: 1 })).toBe(false)
    expect(sameHostStatus(null, null)).toBe(true)
    expect(sameHostStatus(null, { mode: 'local' })).toBe(false)
  })
})

describe('statusView without the host', () => {
  it('says what it always did for personal boards', () => {
    expect(shown('personal', false, 'local').label).toBe('On this Mac')
    expect(shown('personal', true, 'connecting')).toMatchObject({ key: 'connecting', pulse: true })
    expect(shown('personal', true, 'online')).toMatchObject({ key: 'live', label: 'Live', tone: 'success' })
    expect(shown('personal', true, 'offline')).toMatchObject({ key: 'offline', tone: 'warning' })
  })

  it('calls a shared board without its socket offline, not local', () => {
    const s = shown('shared', false, 'local')
    expect(s.key).toBe('offline')
    expect(s.label).toBe('Offline · changes saved on this Mac')
    expect(s.short).toBe('Offline')
  })
})

describe('statusView with the host', () => {
  it('believes the host about a disconnected board, with what is pending', () => {
    const s = shown('shared', true, 'online', { mode: 'shared-offline', pending: 4 })
    expect(s).toMatchObject({ key: 'offline', tone: 'warning', pending: 4 })
    expect(s.label).toBe('Offline · changes saved on this Mac · 4 pending')
    expect(s.short).toBe('Offline · 4 pending')
    expect(s.hint).toMatch(/4 changes waiting to sync/)
    expect(shown('shared', false, 'local', { mode: 'shared-offline', pending: 1 }).hint).toMatch(/1 change waiting/)
    expect(shown('personal', true, 'online', { mode: 'local' }).label).toBe('On this Mac')
  })

  it('says live or synced only once the socket has synced', () => {
    expect(shown('shared', true, 'online', { mode: 'shared-live' })).toMatchObject({ key: 'live', label: 'Live' })
    expect(shown('personal', true, 'online', { mode: 'personal-synced' })).toMatchObject({ key: 'synced', label: 'Synced' })
    expect(shown('shared', true, 'connecting', { mode: 'shared-live' }).key).toBe('connecting')
    expect(shown('shared', true, 'offline', { mode: 'shared-live', pending: 2 })).toMatchObject({ key: 'offline', pending: 2 })
    expect(shown('personal', false, 'local', { mode: 'personal-synced' }).key).toBe('offline')
  })

  it('does not promise saved changes on a view-only board', () => {
    const s = statusView({ kind: 'shared', online: false, sync: 'local', host: { mode: 'shared-offline', pending: 2 }, readOnly: true })
    expect(s).toMatchObject({ key: 'offline', short: 'Offline', pending: 0 })
    expect(s.label).not.toMatch(/changes/)
  })

  it('only counts pending changes while offline', () => {
    expect(shown('shared', true, 'online', { mode: 'shared-live', pending: 3 })).toMatchObject({ label: 'Live', pending: 0 })
  })
})

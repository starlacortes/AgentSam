import { describe, expect, it } from 'vitest'
import { formatShortDate } from '../components/ui'
import { missionTabTitle } from '../pages/MissionPage'
import { displayText, fileKind, mimeType } from './files'
import { reconnectDelay } from './useLiveMission'
import { crc32, makeZip } from './zip'

describe('zip', () => {
  it('computes the standard CRC-32', () => {
    expect(crc32(new TextEncoder().encode('123456789'))).toBe(0xcbf43926)
  })

  it('writes local headers, a central directory and an end record', () => {
    const zip = makeZip([
      { name: 'a.md', text: '# hi' },
      { name: 'b.json', text: '{}' },
    ])
    const view = new DataView(zip.buffer)
    expect(view.getUint32(0, true)).toBe(0x04034b50)
    const end = zip.length - 22
    expect(view.getUint32(end, true)).toBe(0x06054b50)
    expect(view.getUint16(end + 10, true)).toBe(2)
    const centralStart = view.getUint32(end + 16, true)
    expect(view.getUint32(centralStart, true)).toBe(0x02014b50)
  })
})

describe('files', () => {
  it('renders markdown and shows everything else as text', () => {
    expect(fileKind('final-report.md')).toBe('markdown')
    expect(fileKind('notes')).toBe('markdown')
    expect(fileKind('data.csv')).toBe('text')
    expect(fileKind('script.py')).toBe('text')
  })

  it('downloads with a type that matches the extension', () => {
    expect(mimeType('data.csv')).toBe('text/csv;charset=utf-8')
    expect(mimeType('x.json')).toBe('application/json;charset=utf-8')
    expect(mimeType('weird.xyz')).toBe('text/plain;charset=utf-8')
  })

  it('pretty-prints valid JSON only', () => {
    expect(displayText('a.json', '{"a":1}')).toBe('{\n  "a": 1\n}')
    expect(displayText('a.json', '{oops')).toBe('{oops')
  })
})

describe('live updates', () => {
  it('backs off when reconnecting, up to 15 seconds', () => {
    expect([1, 2, 3, 4, 5, 9].map(reconnectDelay)).toEqual([1000, 2000, 4000, 8000, 15000, 15000])
  })
})

describe('tab titles', () => {
  it('shows status and a short objective', () => {
    expect(missionTabTitle({ status: 'running', objective: 'Plan a  3-day\nKyoto trip' })).toBe('● Running · Plan a 3-day Kyoto trip')
    const long = missionTabTitle({ status: 'completed', objective: 'x'.repeat(80) })
    expect(long.startsWith('✓ Done · ')).toBe(true)
    expect(long.endsWith('…')).toBe(true)
  })
})

describe('formatShortDate', () => {
  it('leaves the year out for this year and the time out for older dates', () => {
    const now = new Date(2026, 10, 24, 12, 0)
    const recent = formatShortDate(new Date(2026, 10, 3, 9, 5).toISOString(), now)
    expect(recent).not.toContain('2026')
    expect(recent).toMatch(/9:05/)
    const old = formatShortDate(new Date(2024, 2, 9, 9, 5).toISOString(), now)
    expect(old).toContain('2024')
    expect(old).not.toMatch(/9:05/)
    expect(formatShortDate(undefined)).toBe('—')
    expect(formatShortDate('nonsense')).toBe('—')
  })
})

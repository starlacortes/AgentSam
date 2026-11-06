import { afterEach, describe, expect, it, vi } from 'vitest'
import { api, ApiError, setUnauthorizedHandler } from './client'

function mockFetch(status: number, body: unknown) {
  const fn = vi.fn(async () =>
    new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } }),
  )
  vi.stubGlobal('fetch', fn)
  return fn
}

afterEach(() => {
  vi.unstubAllGlobals()
  setUnauthorizedHandler(null)
})

describe('api', () => {
  it('sends the CSRF header and same-origin credentials', async () => {
    const fetchMock = mockFetch(200, { ok: true })
    await api('teams', { method: 'POST', body: { name: 'x' } })
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toBe('/api/teams')
    expect(init.credentials).toBe('same-origin')
    expect((init.headers as Record<string, string>)['X-AgentSam-Request']).toBe('1')
    expect(init.body).toBe('{"name":"x"}')
  })

  it('surfaces the server reason on errors', async () => {
    mockFetch(409, { error: true, reason: 'There must be at least one active admin' })
    await expect(api('users/1', { method: 'PATCH', body: {} })).rejects.toEqual(
      new ApiError(409, 'There must be at least one active admin'),
    )
  })

  it('reports an expired session, except on auth endpoints', async () => {
    const handler = vi.fn()
    setUnauthorizedHandler(handler)
    mockFetch(401, { reason: 'Sign in required' })
    await expect(api('teams')).rejects.toBeInstanceOf(ApiError)
    expect(handler).toHaveBeenCalledTimes(1)
    await expect(api('auth/login', { method: 'POST', body: {} })).rejects.toBeInstanceOf(ApiError)
    expect(handler).toHaveBeenCalledTimes(1)
  })
})

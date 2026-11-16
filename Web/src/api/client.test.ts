import { afterEach, describe, expect, it, vi } from 'vitest'
import { api, ApiError, setUnauthorizedHandler, uploadProjectFile } from './client'

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

  it('uploads raw project bytes with the encoded relative path', async () => {
    const fetchMock = mockFetch(201, { path: 'project:notes/todo.md', bytes: 7 })
    const file = new Blob(['content'], { type: 'text/markdown' })
    await expect(uploadProjectFile('chat 1', file, 'notes/todo.md')).resolves.toEqual({ path: 'project:notes/todo.md', bytes: 7 })
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toBe('/api/conversations/chat%201/project/uploads')
    expect(init.method).toBe('POST')
    expect(init.credentials).toBe('same-origin')
    expect(init.body).toBe(file)
    expect(init.headers).toMatchObject({
      'Content-Type': 'application/octet-stream',
      'X-AgentSam-Request': '1',
      'X-AgentSam-Path': 'notes%2Ftodo.md',
    })
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

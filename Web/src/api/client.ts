// Thin fetch wrapper for the AgentSam server. Same origin only: the session cookie is HttpOnly,
// so the token never touches JavaScript.

import { currentLanguage, translate } from '../i18n'

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message)
    this.name = 'ApiError'
  }
}

type Method = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'

let onUnauthorized: (() => void) | null = null

/** Called whenever the server says the session is gone, so the app can return to the sign-in page. */
export function setUnauthorizedHandler(handler: (() => void) | null): void {
  onUnauthorized = handler
}

export async function api<T>(path: string, options: { method?: Method; body?: unknown } = {}): Promise<T> {
  const { method = 'GET', body } = options
  const headers: Record<string, string> = {
    Accept: 'application/json',
    // Server-generated messages (errors, notices) come back in the selected UI language.
    'Accept-Language': currentLanguage(),
    // Required by the server for cookie-authenticated writes (CSRF protection).
    'X-AgentSam-Request': '1',
  }
  if (body !== undefined) headers['Content-Type'] = 'application/json'

  const response = await fetch(`/api/${path.replace(/^\//, '')}`, {
    method,
    headers,
    credentials: 'same-origin',
    body: body === undefined ? undefined : JSON.stringify(body),
  })

  if (!response.ok) {
    let reason = response.statusText || `Request failed (${response.status})`
    try {
      const data = (await response.json()) as { reason?: string }
      if (data.reason) reason = data.reason
    } catch {
      // Not JSON; keep the status text.
    }
    if (response.status === 401 && !path.startsWith('auth/')) onUnauthorized?.()
    throw new ApiError(response.status, reason)
  }

  const type = response.headers.get('content-type') ?? ''
  if (type.includes('application/json')) return (await response.json()) as T
  return (await response.text()) as unknown as T
}

export function errorMessage(error: unknown): string {
  if (error instanceof ApiError) return error.message
  if (error instanceof Error) return error.message
  return translate('Something went wrong')
}

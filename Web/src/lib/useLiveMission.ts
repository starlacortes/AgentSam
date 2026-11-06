import { useCallback, useEffect, useRef, useState } from 'react'
import { api, errorMessage } from '../api/client'
import type { MissionDetail, RunEvent } from '../api/types'
import { mergeEvents } from './missionPresentation'

const REFRESH_KINDS = new Set<RunEvent['kind']>(['phase', 'taskStarted', 'taskDone', 'cost', 'deliverable', 'verifyVerdict', 'missionEnd'])
const POLL_MS = 3000
const LIVE_POLL_MS = 15000

export type LiveConnection = 'idle' | 'connecting' | 'live' | 'reconnecting'

/** 1s, 2s, 4s… capped at 15s. */
export function reconnectDelay(attempt: number): number {
  return Math.min(15000, 1000 * 2 ** Math.max(0, attempt - 1))
}

/**
 * Loads a mission and keeps it live: a WebSocket stream (authenticated by the session cookie)
 * plus a polling fallback on `events?afterSeq=` while the mission is running, like the iPhone app.
 */
export function useLiveMission(missionID: string) {
  const [detail, setDetail] = useState<MissionDetail | null>(null)
  const [events, setEvents] = useState<RunEvent[]>([])
  const [error, setError] = useState<string | null>(null)
  const [connection, setConnection] = useState<LiveConnection>('idle')
  const lastSeq = useRef(0)
  const refreshTimer = useRef<number | null>(null)

  const load = useCallback(async () => {
    try {
      const next = await api<MissionDetail>(`missions/${missionID}`)
      setDetail(next)
      setEvents((prev) => {
        const merged = mergeEvents(prev, next.events)
        lastSeq.current = merged[merged.length - 1]?.seq ?? 0
        return merged
      })
      setError(null)
    } catch (err) {
      setError(errorMessage(err))
    }
  }, [missionID])

  // Coalesce bursts of important events into one detail reload.
  const scheduleRefresh = useCallback(() => {
    if (refreshTimer.current !== null) return
    refreshTimer.current = window.setTimeout(() => {
      refreshTimer.current = null
      void load()
    }, 400)
  }, [load])

  const addEvents = useCallback(
    (incoming: RunEvent[]) => {
      if (incoming.length === 0) return
      setEvents((prev) => {
        const merged = mergeEvents(prev, incoming)
        lastSeq.current = merged[merged.length - 1]?.seq ?? 0
        return merged
      })
      if (incoming.some((e) => REFRESH_KINDS.has(e.kind))) scheduleRefresh()
    },
    [scheduleRefresh],
  )

  const catchUp = useCallback(async () => {
    try {
      addEvents(await api<RunEvent[]>(`missions/${missionID}/events?afterSeq=${lastSeq.current}`))
    } catch {
      // The next tick will retry.
    }
  }, [missionID, addEvents])

  useEffect(() => {
    setDetail(null)
    setEvents([])
    lastSeq.current = 0
    void load()
  }, [load])

  const running = detail ? detail.running || detail.mission.status === 'running' || detail.mission.status === 'queued' : true

  // WebSocket while running, reconnecting with backoff when the connection drops.
  useEffect(() => {
    if (!running) {
      setConnection('idle')
      return
    }
    let socket: WebSocket | null = null
    let retryTimer: number | null = null
    let attempt = 0
    let disposed = false

    const open = () => {
      if (disposed) return
      setConnection(attempt === 0 ? 'connecting' : 'reconnecting')
      const scheme = window.location.protocol === 'https:' ? 'wss' : 'ws'
      socket = new WebSocket(`${scheme}://${window.location.host}/api/missions/${missionID}/live`)
      socket.onopen = () => {
        attempt = 0
        setConnection('live')
        // Catch up on anything sent while we were disconnected.
        void catchUp()
      }
      socket.onclose = () => {
        if (disposed) return
        setConnection('reconnecting')
        attempt += 1
        retryTimer = window.setTimeout(open, reconnectDelay(attempt))
      }
      socket.onerror = () => socket?.close()
      socket.onmessage = (message) => {
        try {
          addEvents([JSON.parse(String(message.data)) as RunEvent])
        } catch {
          // Ignore malformed frames.
        }
      }
    }

    // Reconnect right away when the tab comes back or the network returns.
    const wake = () => {
      if (document.visibilityState !== 'visible' || socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) return
      if (retryTimer !== null) window.clearTimeout(retryTimer)
      attempt = Math.max(attempt, 1)
      open()
    }
    document.addEventListener('visibilitychange', wake)
    window.addEventListener('online', wake)

    open()
    return () => {
      disposed = true
      document.removeEventListener('visibilitychange', wake)
      window.removeEventListener('online', wake)
      if (retryTimer !== null) window.clearTimeout(retryTimer)
      socket?.close()
    }
  }, [missionID, running, addEvents, catchUp])

  // Polling fallback: fast while the socket is down, slow while it is up (catches anything it missed).
  useEffect(() => {
    if (!running) return
    const timer = window.setInterval(
      () => {
        if (document.visibilityState === 'visible') void catchUp()
      },
      connection === 'live' ? LIVE_POLL_MS : POLL_MS,
    )
    return () => window.clearInterval(timer)
  }, [running, connection, catchUp])

  useEffect(
    () => () => {
      if (refreshTimer.current !== null) window.clearTimeout(refreshTimer.current)
    },
    [],
  )

  return { detail, events, error, connection, running, reload: load }
}

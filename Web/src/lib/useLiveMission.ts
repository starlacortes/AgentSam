import { useCallback, useEffect, useRef, useState } from 'react'
import { api, errorMessage } from '../api/client'
import type { MissionDetail, RunEvent } from '../api/types'
import { mergeEvents } from './missionPresentation'

const REFRESH_KINDS = new Set<RunEvent['kind']>(['phase', 'taskStarted', 'taskDone', 'cost', 'deliverable', 'verifyVerdict', 'missionEnd'])
const POLL_MS = 3000

/**
 * Loads a mission and keeps it live: a WebSocket stream (authenticated by the session cookie)
 * plus a polling fallback on `events?afterSeq=` while the mission is running, like the iPhone app.
 */
export function useLiveMission(missionID: string) {
  const [detail, setDetail] = useState<MissionDetail | null>(null)
  const [events, setEvents] = useState<RunEvent[]>([])
  const [error, setError] = useState<string | null>(null)
  const [connected, setConnected] = useState(false)
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

  useEffect(() => {
    setDetail(null)
    setEvents([])
    lastSeq.current = 0
    void load()
  }, [load])

  const running = detail ? detail.running || detail.mission.status === 'running' || detail.mission.status === 'queued' : true

  // WebSocket while running.
  useEffect(() => {
    if (!running) return
    const scheme = window.location.protocol === 'https:' ? 'wss' : 'ws'
    const socket = new WebSocket(`${scheme}://${window.location.host}/api/missions/${missionID}/live`)
    socket.onopen = () => setConnected(true)
    socket.onclose = () => setConnected(false)
    socket.onerror = () => setConnected(false)
    socket.onmessage = (message) => {
      try {
        addEvents([JSON.parse(String(message.data)) as RunEvent])
      } catch {
        // Ignore malformed frames.
      }
    }
    return () => socket.close()
  }, [missionID, running, addEvents])

  // Polling fallback (also catches anything the socket missed).
  useEffect(() => {
    if (!running) return
    const timer = window.setInterval(async () => {
      try {
        addEvents(await api<RunEvent[]>(`missions/${missionID}/events?afterSeq=${lastSeq.current}`))
      } catch {
        // Next tick will retry.
      }
    }, POLL_MS)
    return () => window.clearInterval(timer)
  }, [missionID, running, addEvents])

  useEffect(
    () => () => {
      if (refreshTimer.current !== null) window.clearTimeout(refreshTimer.current)
    },
    [],
  )

  return { detail, events, error, connected, running, reload: load }
}

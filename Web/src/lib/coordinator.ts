import type { AgentActivity, Conversation, ConversationMessage, ConnectorStatus } from '../api/types'
import { pickEntry, type PreviewSource } from './preview'

/** Someone who worked on a reply besides Ada: a helper she delegated to, or a specialist from a skill run. */
export interface WorkHelper {
  key: string
  name: string
  /** A helper Ada spawned with `delegate` (researchAda), as opposed to a skill's specialist. */
  helper: boolean
  /** For a skill's specialist: the kind of work it was part of (the skill's name). */
  group?: string
  summary: string
  state: 'working' | 'done' | 'failed' | 'waiting'
}

export interface WorkPresentation {
  activities: AgentActivity[]
  running: boolean
  direct: boolean
  /** Names of the kinds of help Ada brought in (the skills that ran), from the activity itself. */
  helpNames: string[]
  /** What Ada is doing right now, in plain words, while a reply runs. */
  now: string | null
  /** Everyone besides Ada who worked on the latest reply. */
  helpers: WorkHelper[]
}

/** `teamName` the server puts on a helper's activity line. */
export const HELPER_ACTIVITY = 'Helper'

function helperState(state: string): WorkHelper['state'] {
  if (state === 'working' || state === 'done' || state === 'failed') return state
  return 'waiting'
}

export function presentWork(conversation: Conversation | null): WorkPresentation {
  const messages = conversation?.messages ?? []
  const running = [...messages].reverse().find((message) => message.role === 'assistant' && message.status === 'running')
  const latest = running ?? [...messages].reverse().find((message) => message.role === 'assistant' && message.activity.length > 0)
  const activity = latest?.activity ?? []
  const helpNames = [...new Set(activity.map((item) => item.teamName).filter((name): name is string => Boolean(name) && name !== HELPER_ACTIVITY))]
  const now = running
    ? [...(running.steps ?? [])].reverse().find((step) => step.state === 'working')?.label
      ?? running.activity.find((item) => item.agentName === 'Ada' && item.state === 'working')?.summary
      ?? null
    : null
  const helpers = activity
    .filter((item) => item.agentName !== 'Ada')
    .map((item, index): WorkHelper => ({
      key: `${item.teamID ?? 'helper'}-${item.agentID}-${index}`,
      name: item.agentName,
      helper: item.teamName === HELPER_ACTIVITY,
      group: item.teamName && item.teamName !== HELPER_ACTIVITY ? item.teamName : undefined,
      summary: item.summary,
      state: helperState(item.state),
    }))
  return {
    activities: activity,
    running: Boolean(running),
    direct: !latest || latest.teamIDs.length === 0,
    helpNames,
    now,
    helpers,
  }
}

export function visibleAssistantText(message: ConversationMessage): string {
  return message.status === 'running' ? '' : message.text
}

export function connectorLabel(connector: ConnectorStatus | undefined): 'Gmail connected' | 'Gmail off' | 'Connect Gmail' {
  if (!connector?.configured) return 'Connect Gmail'
  return connector.enabled ? 'Gmail connected' : 'Gmail off'
}

export function groupedConversations<T extends { id: string; projectName: string }>(conversations: T[]): [string, T[]][] {
  const groups = new Map<string, T[]>()
  for (const conversation of conversations) {
    const project = conversation.projectName.trim() || 'Personal'
    groups.set(project, [...(groups.get(project) ?? []), conversation])
  }
  return [...groups.entries()]
}

/**
 * Plain words for the voice. Mirrors `SpeechClient.spokenText` on the server; change both together.
 * Drops the suggestions block and any on-screen details, code, tables, bare links, IDs and folder
 * paths; turns headings and list items into sentences; strips Markdown marks but keeps hyphens in words.
 */
export function voiceTranscript(markdown: string, lang: 'en' | 'es' = 'en'): string {
  const words = SCREEN_WORDS[lang]
  let text = markdown
  for (const fence of ['```suggestions', '```details']) {
    const at = text.toLowerCase().indexOf(fence)
    if (at >= 0) text = text.slice(0, at)
  }
  return text
    .replace(/```[\s\S]*?```/g, ` ${words.code} `)
    .replace(/```[\s\S]*$/, ' ')
    .replace(TABLE, ` ${words.table}\n`)
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/https?:\/\/[^\s)]*[^\s).,!?;:]/g, words.link)
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, '')
    .replace(/(?:[\w.~-]+\/)+([\w-]+\.[A-Za-z0-9]+)/g, '$1')
    .replace(/^[ \t]*(?:#{1,6}|[-*+]|\d+[.)])[ \t]+(.*[^.!?:;,\s])[ \t]*$/gm, '$1.')
    .replace(/^[ \t]*(?:#{1,6}|[-*+]|\d+[.)])[ \t]+/gm, '')
    .replace(/[*_#>`|]/g, '')
    .replace(/\s+/g, ' ')
    .replace(/ ([.,!?])/g, '$1')
    .replace(/(?<!\.)\.\.(?!\.)/g, '.')
    .trim()
    .slice(0, 5000)
}

/** What is said in place of things that are shown but not read. The server says the same (`SpeechClient.spokenText`). */
const SCREEN_WORDS = {
  en: { code: 'Code example omitted from speech.', table: 'The table is on screen.', link: 'the link on screen' },
  es: { code: 'Hay un ejemplo de código en pantalla.', table: 'La tabla está en pantalla.', link: 'el enlace en pantalla' },
}

/** A Markdown table: consecutive lines that start with a pipe. */
const TABLE = /(?:^[ \t]*\|.*(?:\n|$))+/gm

/**
 * Pulls the next sentence worth speaking out of a reply that may still be streaming in.
 * `from` is where the last call stopped (an offset into the speakable text, as returned in `end`).
 * Unfinished code blocks, tables, and the trailing suggestions or details block are never spoken, and short
 * sentences are joined so each request to the voice has a useful amount to say.
 *
 * The very first piece is kept short: if the opening sentence runs past `clauseLimit`
 * characters, it is cut at a comma or similar pause so Ada can start talking sooner.
 */
export function takeSpeakable(raw: string, from: number, final: boolean, minLength = 40, clauseLimit = from === 0 ? FIRST_CLAUSE_LIMIT : 0, lang: 'en' | 'es' = 'en'): { text: string; end: number } | null {
  const words = SCREEN_WORDS[lang]
  let body = raw
  for (const fence of ['```suggestions', '```details']) {
    const at = body.toLowerCase().indexOf(fence)
    if (at >= 0) body = body.slice(0, at)
  }
  if (!final && (body.match(/```/g)?.length ?? 0) % 2 === 1) body = body.slice(0, body.lastIndexOf('```'))
  // A table is announced once, not row by row.
  body = body.replace(/```[\s\S]*?```/g, ` ${words.code} `).replace(/```[\s\S]*$/, '').replace(TABLE, `${words.table}\n`)
  const clause = (limit: number) => takeClause(body, from, minLength, limit, lang)
  const boundary = final ? /[.!?]+["')\]]*(?:\s+|$)|\n+/g : /[.!?]+["')\]]*\s+|\n+/g
  boundary.lastIndex = from
  for (let match = boundary.exec(body); match; match = boundary.exec(body)) {
    const end = match.index + match[0].length
    const text = voiceTranscript(body.slice(from, end), lang)
    if (text.length < minLength) continue
    return (clauseLimit && text.length > clauseLimit && clause(Math.min(end, from + clauseLimit))) || { text, end }
  }
  // No sentence end yet: a long opening sentence can still start at its first pause.
  if (clauseLimit && body.length - from > clauseLimit) {
    const early = clause(from + clauseLimit)
    if (early) return early
  }
  if (!final || from >= body.length) return null
  return { text: voiceTranscript(body.slice(from), lang), end: body.length }
}

/** How long the first spoken piece may get before it is cut at a pause, so the first words play quickly. */
export const FIRST_CLAUSE_LIMIT = 140

/** The longest run of `body` from `from` that ends at a pause (comma, semicolon, colon or dash) before `limit`. */
function takeClause(body: string, from: number, minLength: number, limit: number, lang: 'en' | 'es'): { text: string; end: number } | null {
  const pause = /[,;:]\s+|\s[–—]\s+/g
  pause.lastIndex = from
  let best: { text: string; end: number } | null = null
  for (let match = pause.exec(body); match && match.index < limit; match = pause.exec(body)) {
    const end = match.index + match[0].length
    const text = voiceTranscript(body.slice(from, end), lang)
    if (text.length >= minLength) best = { text, end }
  }
  return best
}

export function shouldPoll(conversation: Conversation | null): boolean {
  return Boolean(conversation?.messages.some((message) => message.status === 'running'))
}

/** How long to wait before the next poll: quick while Ada's answer is streaming in, relaxed while she works. */
export function pollDelay(conversation: Conversation | null): number {
  const streaming = conversation?.messages.some((message) => message.status === 'running' && message.text.length > 0)
  return streaming ? 250 : 900
}

/**
 * What the preview sidebar should show, if anything, once Ada finishes a reply.
 * A page she wrote opens in the preview tab; other files open the file list.
 */
export function canvasForFinishedFiles(
  files: string[] | undefined,
  message: ConversationMessage,
): { tab: 'preview' | 'files'; entry?: string } | null {
  if (message.status !== 'complete' || !files?.length) return null
  const page = pickEntry(files)
  return page ? { tab: 'preview', entry: page } : { tab: 'files' }
}

export function workspaceFileSource(conversationID: string, files: string[] | undefined): PreviewSource {
  const project = files?.[0]?.startsWith('project:') ?? false
  const names = (files ?? []).filter((name) => name.startsWith('project:') === project).map((name) => name.replace(/^project:/, ''))
  return { kind: project ? 'project' : 'chat', conversationID, entry: pickEntry(names) ?? undefined }
}

/** True when this message finished with workspace files Ada wrote this reply. */
export function wroteFreshFiles(message: ConversationMessage): boolean {
  return Boolean(message.fileIDs?.length)
}

/** The browser's IANA time zone (for example "America/Los_Angeles"), sent with each message so Ada knows the local time. */
export function browserTimeZone(): string | undefined {
  try {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone
    return zone && zone.length <= 64 ? zone : undefined
  } catch {
    return undefined
  }
}

import type { AgentActivity, Conversation, ConversationMessage, ConnectorStatus, Team } from '../api/types'
import { pickEntry, type PreviewSource } from './preview'

export interface WorkPresentation {
  activities: AgentActivity[]
  running: boolean
  direct: boolean
  teamNames: string[]
}

export function presentWork(conversation: Conversation | null, teams: Team[]): WorkPresentation {
  const messages = conversation?.messages ?? []
  const running = [...messages].reverse().find((message) => message.role === 'assistant' && message.status === 'running')
  const latest = running ?? [...messages].reverse().find((message) => message.role === 'assistant' && message.activity.length > 0)
  const teamNames = (latest?.teamIDs ?? []).map((id) => teams.find((team) => team.id === id)?.name).filter((name): name is string => Boolean(name))
  return {
    activities: latest?.activity ?? [],
    running: Boolean(running),
    direct: !latest || latest.teamIDs.length === 0,
    teamNames,
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

export function voiceTranscript(markdown: string): string {
  return markdown
    .replace(/```[\s\S]*?```/g, ' Code example omitted from speech. ')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/[*_#>`|-]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 5000)
}

/**
 * Pulls the next sentence worth speaking out of a reply that may still be streaming in.
 * `from` is where the last call stopped (an offset into the speakable text, as returned in `end`).
 * Unfinished code blocks and the trailing suggestions block are never spoken, and short
 * sentences are joined so each request to the voice has a useful amount to say.
 */
export function takeSpeakable(raw: string, from: number, final: boolean, minLength = 40): { text: string; end: number } | null {
  let body = raw
  const suggestions = body.indexOf('```suggestions')
  if (suggestions >= 0) body = body.slice(0, suggestions)
  if (!final && (body.match(/```/g)?.length ?? 0) % 2 === 1) body = body.slice(0, body.lastIndexOf('```'))
  body = body.replace(/```[\s\S]*?```/g, ' Code example omitted from speech. ').replace(/```[\s\S]*$/, '')
  const boundary = final ? /[.!?]+["')\]]*(?:\s+|$)|\n+/g : /[.!?]+["')\]]*\s+|\n+/g
  boundary.lastIndex = from
  for (let match = boundary.exec(body); match; match = boundary.exec(body)) {
    const end = match.index + match[0].length
    const text = voiceTranscript(body.slice(from, end))
    if (text.length >= minLength) return { text, end }
  }
  if (!final || from >= body.length) return null
  return { text: voiceTranscript(body.slice(from)), end: body.length }
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

export function canApprove(message: ConversationMessage): boolean {
  return message.proposal?.status === 'pending' && message.status === 'complete'
}

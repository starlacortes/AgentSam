import type { AgentActivity, Conversation, ConversationMessage, ConnectorStatus, Team } from '../api/types'

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

export function shouldPoll(conversation: Conversation | null): boolean {
  return Boolean(conversation?.messages.some((message) => message.status === 'running'))
}

export function canApprove(message: ConversationMessage): boolean {
  return message.proposal?.status === 'pending' && message.status === 'complete'
}

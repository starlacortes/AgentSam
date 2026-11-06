// Coordinator chat models, mirroring CoordinatorChat.swift.

export type ChatLineKind = 'user' | 'coordinator' | 'action' | 'error'

export interface ChatLine {
  id: string
  kind: ChatLineKind
  text: string
  createdAt: string
  missionID?: string
}

export interface PendingChatAction {
  kind: 'startMission' | 'stopMission'
  summary: string
  teamID?: string
  teamName?: string
  missionID?: string
  createdAt: string
}

export interface CoordinatorChat {
  id: string
  teamID: string
  teamName: string
  title: string
  lines: ChatLine[]
  pendingAction?: PendingChatAction
  language: string
  createdAt: string
  updatedAt: string
  totalCostUSD: number
  totalInputTokens: number
  totalOutputTokens: number
}

export interface ChatSettings {
  defaultTeamID?: string
  effectiveTeamID?: string
}

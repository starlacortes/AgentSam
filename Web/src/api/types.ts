// Mirrors the server's JSON (Server/Sources/AgentSamServer and AgentSamCore/Models.swift).

export type UserRole = 'admin' | 'member'

export interface PublicUser {
  id: string
  email: string
  name: string
  role: UserRole
  disabled: boolean
  createdAt: string
  lastLoginAt?: string
}

export interface Me {
  user?: PublicUser
  via: 'session' | 'token'
  name: string
  role: UserRole
}

export interface PublicInvite {
  id: string
  email: string
  role: UserRole
  createdAt: string
  expiresAt: string
}

export interface InviteCreated {
  invite: PublicInvite
  path: string
}

export interface InvitePreview {
  email: string
  role: UserRole
  expiresAt: string
}

export interface Ack {
  ok: boolean
  detail?: string
}

// MARK: Engine models

export type AgentRole = 'coordinator' | 'worker' | 'verifier'
export type MissionStatus = 'queued' | 'running' | 'completed' | 'failed' | 'stopped'
export type MissionPhase = 'planning' | 'working' | 'verifying' | 'reporting' | 'done'

export interface AgentProfile {
  id: string
  name: string
  emoji: string
  title: string
  role: AgentRole
  systemPrompt: string
  providerID: string
  model: string
  temperature?: number
}

export interface Team {
  id: string
  name: string
  emoji: string
  goal: string
  agents: AgentProfile[]
  createdAt: string
  updatedAt: string
}

export interface Mission {
  id: string
  teamID: string
  teamName: string
  objective: string
  status: MissionStatus
  phase: MissionPhase
  createdAt: string
  startedAt?: string
  finishedAt?: string
  finalReport?: string
  totalCostUSD: number
  totalInputTokens: number
  totalOutputTokens: number
  launchedBy?: string
}

export type RunEventKind =
  | 'missionStart'
  | 'phase'
  | 'plan'
  | 'taskStarted'
  | 'agentMessage'
  | 'toolCall'
  | 'taskDone'
  | 'deliverable'
  | 'verifyFinding'
  | 'verifyVerdict'
  | 'report'
  | 'cost'
  | 'notice'
  | 'missionEnd'
  | 'error'

export interface RunEvent {
  id: string
  seq: number
  missionID: string
  timestamp: string
  kind: RunEventKind
  agentID?: string
  agentName?: string
  text?: string
  deliverableName?: string
  costUSD?: number
}

export interface MissionDetail {
  mission: Mission
  events: RunEvent[]
  deliverables: string[]
  running: boolean
}

export interface ServerInfo {
  name: string
  teams: number
  missions: number
  runningMissions: string[]
}

export const phaseLabel: Record<MissionPhase, string> = {
  planning: 'Planning',
  working: 'Agents working',
  verifying: 'Verifying',
  reporting: 'Final report',
  done: 'Done',
}

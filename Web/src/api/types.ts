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
  /** May use the server's shared Gmail, Ads, GitHub, Cloudflare, Maloon and MCP accounts. Always true for admins. */
  sharedAccounts?: boolean
  /** Has a workstation account of their own. Admins use the operator workstation, so always true for them. */
  workstation?: boolean
  /** Admins only: works in an account of their own on the workstation, with their own browser, instead of Ada's shared one. */
  ownWorkspace?: boolean
}

export interface Me {
  user?: PublicUser
  via: 'session' | 'apiToken' | 'token'
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
  toolScope?: ToolScope
  createdAt: string
  updatedAt: string
}

export interface ToolScope {
  connectorIDs: string[]
  permissions: ConnectorPermissions
}

export interface ConnectorPermissions {
  sendEmail: boolean
  createDraft: boolean
  dnsWrite: boolean
  githubWrite: boolean
  adsWrite?: boolean
}

export type ConnectorId = 'gmail' | 'googleads' | 'cloudflare' | 'github' | 'web'

export interface ConnectorStatus {
  id: ConnectorId
  name: string
  detail: string
  enabled: boolean
  configured: boolean
  permissions: ConnectorPermissions
  oauthAvailable: boolean
}

export interface AgentActivity {
  id: string
  agentID: string
  agentName: string
  summary: string
  state: 'idle' | 'working' | 'done' | 'failed' | string
  updatedAt: string
  teamID?: string
  teamName?: string
}

export interface TeamProposal {
  id: string
  baseTeamID?: string
  team: Team
  rationale: string
  toolScope: ToolScope
  status: 'pending' | 'applied' | 'dismissed'
  createdAt: string
}

/** A photo attached to a chat message. Fetch the image from `/api/conversations/:id/photos/:photoID`. */
export interface PhotoAttachment {
  id: string
  mediaType: string
  bytes: number
}

export interface ConversationMessage {
  id: string
  role: 'user' | 'assistant'
  text: string
  createdAt: string
  status: 'running' | 'complete' | 'failed'
  missionIDs: string[]
  teamIDs: string[]
  proposal?: TeamProposal
  activity: AgentActivity[]
  /** Visible progress steps; absent on conversations saved before they existed. */
  steps?: MessageStep[]
  /** One-click replies: clarifying options or suggested follow-ups. */
  quickReplies?: string[]
  /** Files Ada wrote to the conversation workspace during this reply. */
  fileIDs?: string[]
  /** True when the platform sent this from the conversation's schedule, not the user. */
  scheduled?: boolean
  /** Photos the user attached; absent on older messages. */
  photos?: PhotoAttachment[]
  /** True when the user spoke this message in voice mode. */
  spoken?: boolean
  /** For a reply to a spoken message: the part read aloud; the rest of `text` is on-screen detail. */
  speech?: string
  /** For a reply to a spoken message: a few words to say right away while Ada works ("Let me check your calendar."). */
  acknowledgement?: string
  completedAt?: string
  /** For a run a trigger started: what happened. */
  trigger?: TriggerEvent
  /** True once Ada used her live browser during this reply; the web app then opens it beside the chat. */
  usedBrowser?: boolean
}

export interface TriggerEvent {
  triggerID: string
  kind: 'gmail' | 'webhook'
  data: string
}

export interface MessageStep {
  id: string
  label: string
  state: 'working' | 'done' | 'failed'
  startedAt: string
  finishedAt?: string
}

export interface ConversationSummary {
  id: string
  title: string
  projectName: string
  updatedAt: string
  running: boolean
  /** Set while the chat is archived (hidden from the sidebar until restored or purged). */
  archivedAt?: string | null
}

/** How long archived chats are kept. `retentionDays` absent or null means never delete. */
export interface ArchiveSettings {
  retentionDays?: number | null
  configured: boolean
}

/** A recurring prompt the platform sends on a timer (prompt, interval). */
export interface ConversationSchedule {
  prompt: string
  intervalMinutes: number
  language: string
  createdAt: string
  lastRunAt?: string
  nextRunAt: string
  /** Set times: runs at hour:minute on these ISO weekdays (1 = Monday; empty = every day). */
  at?: ScheduleTime
  failures?: number
  pausedAt?: string
  pauseReason?: string
}

export interface ScheduleTime {
  hour: number
  minute: number
  weekdays: number[]
}

/** Something that wakes the chat: new email matching a Gmail search, or a call to its webhook. */
export interface ConversationTrigger {
  id: string
  kind: 'gmail' | 'webhook'
  prompt: string
  language: string
  query?: string
  token?: string
  createdAt: string
  lastFiredAt?: string
  failures?: number
  pausedAt?: string
  pauseReason?: string
}


export function intervalLabel(minutes: number): string {
  return { 15: 'every 15 minutes', 30: 'every 30 minutes', 60: 'hourly', 360: 'every 6 hours', 720: 'every 12 hours', 1440: 'daily' }[minutes] ?? `every ${minutes} minutes`
}

export interface Conversation extends ConversationSummary {
  ownerID: string
  createdAt: string
  messages: ConversationMessage[]
  schedule?: ConversationSchedule
  triggers?: ConversationTrigger[]
  timeZone?: string
}

export interface HostFolderGrant {
  id: string
  ownerID: string
  path: string
  canWrite: boolean
  createdAt: string
  lastUsedAt?: string
}

export interface AccessAuditEntry {
  id: string
  timestamp: string
  ownerID: string
  action: string
  detail: string
}

export type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue }

export interface AgentActionRequest {
  id: string
  ownerID: string
  conversationID: string
  missionID?: string
  kind: 'connectorWrite' | 'fileDelete' | 'workstation' | 'mcpCall' | 'helperSave' | 'browser'
  title: string
  detail: string
  toolName: string
  arguments: { [key: string]: JSONValue }
  teamID?: string
  toolScope?: ToolScope
  fileScope?: 'conversation' | 'project'
  projectName?: string
  status: 'pending' | 'approved' | 'executing' | 'completed' | 'denied' | 'expired' | 'failed'
  createdAt: string
  expiresAt: string
  result?: string
  /** Ran without a card because a standing permission allowed it. */
  automatic?: boolean
}

export interface WorkspaceMemory {
  enabled: boolean
  markdown: string
  sources: { conversationID: string; userMessageID: string; assistantMessageID: string; timestamp: string }[]
  updatedAt?: string
  compactionCount: number
  pendingEntries: number
  pinned?: PinnedMemory[]
}

export interface PinnedMemory {
  id: string
  text: string
  createdAt: string
  origin: 'ada' | 'person'
}

export type WorkspaceKnowledgeDocumentID = 'capabilities' | 'connections' | 'projects'
export type WorkspaceKnowledgeStatus = 'pending' | 'refreshing' | 'ready' | 'failed'

export interface WorkspaceKnowledgeDocument {
  id: WorkspaceKnowledgeDocumentID
  title: string
  markdown: string
  updatedAt: string
}

export interface WorkspaceKnowledge {
  status: WorkspaceKnowledgeStatus
  documents: WorkspaceKnowledgeDocument[]
  discoveredAt?: string
  updatedAt?: string
  nextRefreshAt?: string
  refreshCount: number
  lastError?: string
}

export interface GuideState {
  completed: boolean
  resetAt?: string
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
  /** The Maloon workflow a mission ran, if any. */
  workflowID?: string
  /** The skill a helper task followed, if any. */
  skillID?: string
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

export interface ProviderConfig {
  id: string
  name: string
  kind: 'openAICompatible' | 'anthropic'
  baseURL: string
  models: string[]
  defaultModel?: string
}

export interface ProviderStatus {
  provider: ProviderConfig
  hasKey: boolean
}

export interface VisionModelSetting {
  providerID: string
  model: string
}

export interface TeamTemplate {
  id: string
  name: string
  emoji: string
  goal: string
  summary: string
  capabilities: string[]
  example: string
  memberNames: string[]
  lowCost: boolean
  coverColors: string[]
}

export interface TemplateCatalog {
  templates: { template: TeamTemplate; agents: AgentProfile[] }[]
  missionIdeas: string[]
}

export interface PublicAPIToken {
  id: string
  name: string
  createdAt: string
  lastUsedAt?: string
}

export interface TokenCreated {
  token: PublicAPIToken
  secret: string
}

export interface ProviderTestResult {
  ok: boolean
  message: string
}

export interface ConnectorTestResult {
  ok: boolean
  message: string
}

// MARK: Bulk account provisioning

export type BatchStatus = 'queued' | 'running' | 'paused' | 'done' | 'cancelled'
export type ProvisioningItemState = 'pending' | 'creating' | 'done' | 'failed' | 'cancelled'
export type ProvisioningDelivery = 'inviteLinks' | 'directPasswords'

export interface BatchSpec {
  count: number
  role: UserRole
  domains: string[]
  delivery: ProvisioningDelivery
  paceSeconds: [number, number]
  expiresInDays?: number
}

export interface ProvisioningItem {
  id: string
  state: ProvisioningItemState
  email?: string
  userID?: string
  attemptCount: number
  lastError?: string
  completedAt?: string
  secret?: string
  secretAcknowledged: boolean
}

export interface PublicBatch {
  id: string
  createdBy?: string
  createdAt: string
  spec: BatchSpec
  status: BatchStatus
  items: ProvisioningItem[]
}

export interface BatchDetail {
  batch: PublicBatch
}

export interface MCPToolView {
  name: string
  exposedName: string
  description: string
  readOnlyHint: boolean
  read: boolean
}

export interface MCPServerView {
  id: string
  name: string
  slug: string
  url: string
  enabled: boolean
  hasToken: boolean
  tools: MCPToolView[]
  lastRefreshed?: string
  lastError?: string
}

export interface MCPSuggestionView {
  id: string
  name: string
  url: string
  detail: string
  added: boolean
}

export type PermissionMode = 'ask' | 'allow' | 'never'

export interface PermissionRule {
  mode: PermissionMode
  maxPerDay?: number
  maxAmount?: number
  branchPrefix?: string
  allowedRecipients?: string[]
  commandPrefixes?: string[]
}

export interface PermissionPolicy {
  paused: boolean
  rules: { [tool: string]: PermissionRule }
  approvalMinutes: number
  dailySpendCapUSD?: number
  replySpendCapUSD?: number
}

export interface PermissionsView {
  policy: PermissionPolicy
  usageToday: { [tool: string]: number }
  tools: string[]
  canEdit: boolean
  spentTodayUSD: number
  workstation?: boolean
}

/** Ada's live browser on her workstation, as GET /api/browser reports it. */
export interface BrowserView {
  available: boolean
  state?: 'running' | 'stopped' | 'unreachable' | null
  idleMinutes?: number | null
  drivable?: boolean | null
}

/** Who is in control of Ada's browser. */
export type BrowserControl = 'ada' | 'paused' | 'person'

/** What POST /api/browser/start returns: the state and what the viewer needs to connect. */
export interface BrowserSessionView {
  state: string
  password: string
  /** True when Ada can drive the browser; the window then shows Take over and Hand back. */
  drivable?: boolean | null
  control?: BrowserControl | null
}

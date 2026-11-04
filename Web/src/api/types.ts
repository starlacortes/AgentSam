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

import type { RoomDO } from './room';
import type { OwnerDO } from './owner';

export const EV = 1;

export interface RelayEnv {
  ROOM: DurableObjectNamespace<RoomDO>;
  OWNER: DurableObjectNamespace<OwnerDO>;
  MEMBERSHIP?: string;
  CREATE_PASSWORD?: string;
  SELFHOST_MAX_MEMBERS?: string;
  HOST_GRACE_MS?: string;
  PENDING_TIMEOUT_MS?: string;
  JOIN_TIMEOUT_MS?: string;
  IDLE_TIMEOUT_MS?: string;
  ROOM_LIFETIME_MS?: string;
  RATE_DROP_CLOSE?: string;
  JOIN_RATE_MAX?: string;
  CREATE_RATE_MAX?: string;
}

export type Tier = 'cutie' | 'pookie' | 'patootie' | 'owner' | 'selfhost';

export interface Ban {
  id: string;
  name: string;
  did: string;
  ip: string;
}

export interface RoomState {
  code: string;
  pv: number;
  createdAt: number;
  maxMembers: number;
  tier: Tier;
  ownerId: string | null;
  hostN: number | null;
  nextN: number;
  approval: boolean;
  pwHash: string | null;
  locked: boolean;
  successors: number[];
  bans: Ban[];
  hostGraceUntil: number | null;
  idleSince: number | null;
}

export interface MemberRec {
  n: number;
  name: string;
  did: string;
  ip: string;
  th: string;
}

/** Per socket state, persisted through hibernation. Kept tiny (attachment cap is 2 KiB). */
export interface Att {
  ip: string;
  /** member number, set once welcomed */
  n?: number;
  name?: string;
  did?: string;
  /** join deadline while not welcomed */
  jd?: number;
  /** pending request id */
  p?: string;
  /** pending deadline */
  pd?: number;
}

export interface CreateInit {
  code: string;
  pv: number;
  name: string;
  did: string;
  ip: string;
  approval: boolean;
  password: string | null;
  maxMembers: number;
  tier: Tier;
  ownerId: string | null;
}

export type LeaveReason = 'leave' | 'lost' | 'kick' | 'ban' | 'replaced';

import type { RoomDO } from './room';
import type { OwnerDO } from './owner';
import type { DirectoryDO } from './directory';

export const EV = 1;

export interface RelayEnv {
  ROOM: DurableObjectNamespace<RoomDO>;
  OWNER: DurableObjectNamespace<OwnerDO>;
  DIR: DurableObjectNamespace<DirectoryDO>;
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
  DIRECTORY?: string;
  DIRECTORY_REFRESH_MS?: string;
  DIRECTORY_TTL_MS?: string;
  LIST_RATE_MAX?: string;
}

export type Tier = 'cutie' | 'pookie' | 'patootie' | 'owner' | 'selfhost';

export interface Ban {
  id: string;
  name: string;
  did: string;
  ip: string;
}

/** What the host last told the directory about the room. */
export interface Summary {
  name: string;
  title: string | null;
  artist: string | null;
}

export interface RoomState {
  code: string;
  pv: number;
  createdAt: number;
  maxMembers: number;
  tier: Tier;
  ownerId: string | null;
  /** first 8 hex of sha-256 of the owner identity, shown in the directory */
  hid: string;
  hostN: number | null;
  nextN: number;
  approval: boolean;
  pwHash: string | null;
  locked: boolean;
  pub: boolean;
  summary: Summary | null;
  /** when the directory entry was last pushed, null while the room is not listed */
  dirAt: number | null;
  /** the entry changed within the refresh window, so a push is owed at `dirAt + refresh` */
  dirStale: boolean;
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
  pub: boolean;
  maxMembers: number;
  tier: Tier;
  ownerId: string | null;
  hid: string;
}

export type LeaveReason = 'leave' | 'lost' | 'kick' | 'ban' | 'replaced';

/** One listed room, as the rooms push it and the directory keeps it. */
export interface DirEntry {
  code: string;
  name: string;
  hid: string;
  members: number;
  max: number;
  pv: number;
  approval: boolean;
  password: boolean;
  title: string | null;
  artist: string | null;
  at: number;
}

/** A directory entry as `GET /v1/rooms` serves it: no `title`/`artist` key when there is none. */
export interface PublicRoom {
  code: string;
  name: string;
  hid: string;
  members: number;
  max: number;
  pv: number;
  approval: boolean;
  password: boolean;
  title?: string;
  artist?: string;
  at: number;
}

export interface ListQuery {
  ip: string;
  limit: number;
  after: string | null;
  ttlMs: number;
  rateMax: number;
}

export interface ListResult {
  limited: boolean;
  rooms: PublicRoom[];
  next: string | null;
}

import 'dart:typed_data';

/// relay envelope version, `ev` in `/v1/info`.
const int kEnvelopeVersion = 1;
const String kRelayName = 'namida-party';

/// `[route u8][n u32 big endian][payload...]`
const int kDataHeaderSize = 5;

/// websocket close code used for every relay initiated close.
const int kRelayCloseCode = 4000;

const String kRoomCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const int kRoomCodeLength = 8;

const int kMaxNameLength = 32;
const int kMaxDidLength = 64;
const int kMaxPasswordLength = 64;
const int kMaxTokenLength = 128;

abstract final class DataRoute {
  /// to the host, `n` ignored.
  static const int host = 0;

  /// host -> every connected member except the host, `n` = member to skip (0 for none).
  static const int broadcast = 1;

  /// host -> member `n`.
  static const int member = 2;
}

abstract final class Ctrl {
  static const String join = 'join';
  static const String welcome = 'welcome';
  static const String pending = 'pending';
  static const String error = 'error';
  static const String ping = 'ping';
  static const String pong = 'pong';
  static const String leave = 'leave';
  static const String kick = 'kick';
  static const String unban = 'unban';
  static const String approve = 'approve';
  static const String transfer = 'transfer';
  static const String successors = 'successors';
  static const String opts = 'opts';
  static const String close = 'close';
  static const String joined = 'joined';
  static const String left = 'left';
  static const String host = 'host';
  static const String joinreq = 'joinreq';
  static const String joinreqgone = 'joinreqgone';
  static const String bans = 'bans';
  static const String closed = 'closed';
}

abstract final class RelayErrors {
  static const String badRequest = 'bad_request';
  static const String membershipRequired = 'membership_required';
  static const String membershipInvalid = 'membership_invalid';
  static const String badPassword = 'bad_password';
  static const String roomsLimit = 'rooms_limit';
  static const String rateLimited = 'rate_limited';
  static const String upstream = 'upstream';
  static const String notFound = 'not_found';
  static const String versionMismatch = 'version_mismatch';
  static const String full = 'full';
  static const String banned = 'banned';
  static const String rejected = 'rejected';
  static const String locked = 'locked';
  static const String timeout = 'timeout';
  static const String hostOffline = 'host_offline';
  static const String forbidden = 'forbidden';
  static const String tooLarge = 'too_large';
  static const String kicked = 'kicked';
}

abstract final class LeftReason {
  static const String leave = 'leave';
  static const String lost = 'lost';
  static const String kick = 'kick';
  static const String ban = 'ban';
  static const String replaced = 'replaced';
}

abstract final class ClosedReason {
  static const String host = 'host';
  static const String idle = 'idle';
  static const String expired = 'expired';
}

abstract final class RelayTier {
  static const String cutie = 'cutie';
  static const String pookie = 'pookie';
  static const String patootie = 'patootie';
  static const String owner = 'owner';
  static const String selfhost = 'selfhost';
}

abstract final class AuthKind {
  static const String patreon = 'patreon';
  static const String supabase = 'supabase';
  static const String password = 'password';
}

final Set<int> _roomCodeUnits = kRoomCodeAlphabet.codeUnits.toSet();

/// upper cased [raw], or null when it can not be a room code.
String? normalizeRoomCode(String raw) {
  if (raw.length != kRoomCodeLength) return null;
  final code = raw.toUpperCase();
  for (var i = 0; i < kRoomCodeLength; i++) {
    if (!_roomCodeUnits.contains(code.codeUnitAt(i))) return null;
  }
  return code;
}

/// header + payload in a single allocation.
Uint8List encodeDataFrame(int route, int n, List<int> payload) {
  final frame = Uint8List(kDataHeaderSize + payload.length);
  frame[0] = route;
  writeDataFrameN(frame, n);
  frame.setRange(kDataHeaderSize, frame.length, payload);
  return frame;
}

int dataFrameRoute(Uint8List frame) => frame[0];

int dataFrameN(Uint8List frame) => (frame[1] << 24) | (frame[2] << 16) | (frame[3] << 8) | frame[4];

/// rewrites the `n` header field in place, no allocation.
void writeDataFrameN(Uint8List frame, int n) {
  frame[1] = (n >>> 24) & 0xFF;
  frame[2] = (n >>> 16) & 0xFF;
  frame[3] = (n >>> 8) & 0xFF;
  frame[4] = n & 0xFF;
}

/// view over the payload, shares the frame buffer.
Uint8List dataFramePayload(Uint8List frame) => Uint8List.sublistView(frame, kDataHeaderSize);

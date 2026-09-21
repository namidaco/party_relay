import 'dart:convert';

import 'config.dart';
import 'envelope.dart';

/// no entry ever expires this late.
const int _never = 1 << 62;

/// a room as the directory sees it.
abstract interface class DirectoryRoom {
  /// refreshes [directoryEntry] when it is due, true when the listing may have moved.
  bool refreshDirectory(int nowMs);

  /// null while the room is not publishable (not public, no summary, gone).
  DirectoryEntry? get directoryEntry;
}

/// the published snapshot of one room, refreshed in place so a listing allocates nothing per room.
class DirectoryEntry {
  DirectoryEntry({required this.code, required this.hid, required this.max, required this.pv});

  final String code;
  final String hid;
  final int max;
  final int pv;

  String name = '';
  String? title;
  String? artist;
  int members = 0;
  int atMs = 0;
  bool approval = false;
  bool password = false;
  bool locked = false;

  bool get listed => members > 0 && !locked && name.isNotEmpty;

  Map<String, Object?> toJson() => {
        'code': code,
        'name': name,
        'hid': hid,
        'members': members,
        'max': max,
        'pv': pv,
        'approval': approval,
        'password': password,
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        'at': atMs,
      };
}

/// `GET /v1/rooms`, derived from the live rooms. the sorted list is cached and rebuilt only when an entry moved.
class RelayDirectory {
  RelayDirectory(this.config, this._rooms);

  final PartyRelayConfig config;
  final Map<String, DirectoryRoom> _rooms;
  final List<DirectoryEntry> _listed = [];
  bool _valid = false;
  int _expiresMs = _never;

  /// rooms came or went, the cached list can not be trusted.
  void invalidate() => _valid = false;

  Map<String, Object?> page(int nowMs, int? limit, String? after) {
    final entries = _snapshot(nowMs);
    final size = limit == null || limit < 1
        ? config.directoryPageSize
        : limit > config.directoryListLimit
            ? config.directoryListLimit
            : limit;
    final start = after == null || after.isEmpty ? 0 : _cursorStart(entries, after);
    final end = start + size > entries.length ? entries.length : start + size;
    final rooms = List<Map<String, Object?>>.generate(end - start, (i) => entries[start + i].toJson(), growable: false);
    return {'rooms': rooms, 'next': end > start && end < entries.length ? _encodeCursor(end, entries[end - 1].code) : null};
  }

  List<DirectoryEntry> _snapshot(int nowMs) {
    var changed = !_valid || nowMs >= _expiresMs;
    for (final room in _rooms.values) {
      if (room.refreshDirectory(nowMs)) changed = true;
    }
    if (!changed) return _listed;

    final ttlMs = config.directoryEntryTtl.inMilliseconds;
    var expires = _never;
    _listed.clear();
    for (final room in _rooms.values) {
      final entry = room.directoryEntry;
      if (entry == null || !entry.listed) continue;
      final expiry = entry.atMs + ttlMs;
      if (expiry <= nowMs) continue;
      if (expiry < expires) expires = expiry;
      _listed.add(entry);
    }
    _listed.sort(_byMembers);
    _expiresMs = expires;
    _valid = true;
    return _listed;
  }
}

int _byMembers(DirectoryEntry a, DirectoryEntry b) {
  if (a.members != b.members) return b.members - a.members;
  if (a.atMs != b.atMs) return b.atMs > a.atMs ? 1 : -1;
  return a.code.compareTo(b.code);
}

String _encodeCursor(int offset, String code) => base64Url.encode(utf8.encode('$offset.$code')).replaceAll('=', '');

/// the offset is a hint, the code wins when entries moved between pages.
int _cursorStart(List<DirectoryEntry> entries, String cursor) {
  if (cursor.length > kMaxCursorLength) return 0;
  String decoded;
  try {
    decoded = utf8.decode(base64Url.decode(base64Url.normalize(cursor)));
  } catch (_) {
    return 0;
  }
  final dot = decoded.indexOf('.');
  if (dot <= 0) return 0;
  final offset = int.tryParse(decoded.substring(0, dot));
  if (offset == null || offset < 0) return 0;
  final code = decoded.substring(dot + 1);
  final start = offset > entries.length ? entries.length : offset;
  if (start > 0 && entries[start - 1].code != code) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].code == code) return i + 1;
    }
  }
  return start;
}

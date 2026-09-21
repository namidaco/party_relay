import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'envelope.dart';
import 'sha256.dart';

final Random _secure = Random.secure();

Uint8List _randomBytes(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = _secure.nextInt(256);
  }
  return bytes;
}

String _base64Url(int length) => base64Url.encode(_randomBytes(length)).replaceAll('=', '');

/// 32 random bytes, base64url.
String newToken() => _base64Url(32);

String newShortId() => _base64Url(9);

String newRoomCode() {
  final code = StringBuffer();
  for (var i = 0; i < kRoomCodeLength; i++) {
    code.writeCharCode(kRoomCodeAlphabet.codeUnitAt(_secure.nextInt(kRoomCodeAlphabet.length)));
  }
  return code.toString();
}

/// length is not secret, contents are.
bool constantTimeEquals(String a, String b) {
  var diff = a.length ^ b.length;
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < shared; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// trimmed, control chars stripped, null when longer than [max].
String? sanitizeText(String raw, int max) {
  if (raw.length > max * 8) return null;
  final out = StringBuffer();
  for (final rune in raw.runes) {
    if (rune >= 0x20 && rune != 0x7F) out.writeCharCode(rune);
  }
  final text = out.toString().trim();
  return text.length > max ? null : text;
}

/// [sanitizeText] that also rejects empty, null when outside 1..[max].
String? sanitizeName(String raw, {int max = kMaxNameLength}) {
  final name = sanitizeText(raw, max);
  return name == null || name.isEmpty ? null : name;
}

/// `hid`, the first 8 hex of sha-256 over the room owner identity.
String identityHid(String identity) => sha256Hex(utf8.encode(identity), kHidBytes);

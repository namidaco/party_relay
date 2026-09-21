import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'config.dart';
import 'envelope.dart';
import 'rate_limit.dart';
import 'room.dart';

class RelayMember {
  RelayMember({required this.n, required this.name, required this.did, required this.ip, required this.token});

  final int n;
  final String did;
  final String ip;
  String name;
  String token;
  RelaySocket? sock;

  bool get connected => sock != null;
}

class PendingJoin {
  PendingJoin({required this.id, required this.sock, required this.name, required this.did});

  final String id;
  final RelaySocket sock;
  final String name;
  final String did;
  Timer? timer;
}

class BanEntry {
  BanEntry({required this.id, required this.name, required this.did, required this.ip});

  final String id;
  final String name;
  final String did;
  final String ip;
}

/// one websocket, plus everything that is per connection (bucket, join deadline, drop counter).
class RelaySocket {
  RelaySocket(this.ws, this.ip, this.config, int nowMs) : bucket = TokenBucket(config.guestBurst, config.guestRefillPerSecond, nowMs);

  final WebSocket ws;
  final String ip;
  final PartyRelayConfig config;
  final TokenBucket bucket;

  RelayRoom? room;
  RelayMember? member;
  PendingJoin? pending;
  Timer? joinTimer;

  bool _closed = false;
  int _drops = 0;
  int _dropWindowMs = 0;
  int _rateErrorMs = 0;

  bool get closed => _closed;
  bool get joined => member != null;

  void sendText(String message) {
    if (_closed) return;
    try {
      ws.add(message);
    } catch (_) {}
  }

  void sendBytes(Uint8List frame) {
    if (_closed) return;
    try {
      ws.add(frame);
    } catch (_) {}
  }

  void sendError(String code, [Map<String, Object?>? extra]) => sendText(encodeError(code, fatal: false, extra: extra));

  void fatal(String code, [Map<String, Object?>? extra]) {
    if (_closed) return;
    sendText(encodeError(code, fatal: true, extra: extra));
    closeNow();
  }

  void closeNow() {
    if (_closed) return;
    _closed = true;
    joinTimer?.cancel();
    joinTimer = null;
    try {
      ws.close(kRelayCloseCode);
    } catch (_) {}
  }

  /// false when the frame must be dropped. sustained drops close the socket.
  bool charge(int nowMs) {
    if (bucket.take(nowMs)) return true;
    if (_dropWindowMs == 0 || nowMs - _dropWindowMs >= config.rateDropWindow.inMilliseconds) {
      _dropWindowMs = nowMs;
      _drops = 0;
    }
    _drops++;
    if (_drops >= config.rateDropClose) {
      fatal(RelayErrors.rateLimited);
      return false;
    }
    if (_rateErrorMs == 0 || nowMs - _rateErrorMs >= config.rateErrorInterval.inMilliseconds) {
      _rateErrorMs = nowMs;
      sendError(RelayErrors.rateLimited);
    }
    return false;
  }
}

String encodeError(String code, {required bool fatal, Map<String, Object?>? extra}) {
  final frame = <String, Object?>{'t': Ctrl.error, 'code': code};
  if (fatal) frame['fatal'] = true;
  if (extra != null) frame.addAll(extra);
  return jsonEncode(frame);
}

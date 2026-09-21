import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'config.dart';
import 'envelope.dart';
import 'ids.dart';
import 'member.dart';
import 'rate_limit.dart';
import 'room.dart';

class PartyRoomCreated {
  const PartyRoomCreated({required this.code, required this.token, required this.max, required this.tier});

  final String code;
  final String token;
  final int max;
  final String tier;

  Map<String, Object?> toJson() => {'code': code, 'token': token, 'max': max, 'tier': tier};
}

class PartyRelayServer {
  PartyRelayServer._(this._http, this.config) {
    _createLimiter = IpRateLimiter(config.createLimit, config.createWindow);
    _joinLimiter = IpRateLimiter(config.joinLimit, config.joinWindow);
    _pruneTimer = Timer.periodic(config.pruneInterval, (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _createLimiter.prune(now);
      _joinLimiter.prune(now);
    });
    _http.listen(_onRequest, onError: (Object _) {}, cancelOnError: false);
  }

  static Future<PartyRelayServer> start({
    Object? address,
    int port = 0,
    PartyRelayConfig config = const PartyRelayConfig(),
    SecurityContext? securityContext,
  }) async {
    final on = address ?? InternetAddress.anyIPv4;
    final http = securityContext == null ? await HttpServer.bind(on, port) : await HttpServer.bindSecure(on, port, securityContext);
    return PartyRelayServer._(http, config);
  }

  final HttpServer _http;
  final PartyRelayConfig config;

  final Map<String, RelayRoom> _rooms = {};
  final Set<RelaySocket> _sockets = {};
  late final IpRateLimiter _createLimiter;
  late final IpRateLimiter _joinLimiter;
  Timer? _pruneTimer;

  int get port => _http.port;
  InternetAddress get address => _http.address;
  int get roomCount => _rooms.length;
  bool hasRoom(String code) => _rooms.containsKey(normalizeRoomCode(code) ?? code);

  /// in process room creation, no http and no create password.
  PartyRoomCreated createRoom({required String name, required String did, int pv = 1, bool approval = false, String? password, int? maxMembers}) {
    final cleanName = sanitizeName(name);
    if (cleanName == null) throw ArgumentError.value(name, 'name', 'must be 1..$kMaxNameLength chars');
    if (did.isEmpty || did.length > kMaxDidLength) throw ArgumentError.value(did, 'did', 'must be 1..$kMaxDidLength chars');
    if (pv < 1) throw ArgumentError.value(pv, 'pv', 'must be >= 1');
    if (password != null && (password.isEmpty || password.length > kMaxPasswordLength)) throw ArgumentError.value(password, 'password', 'must be 1..$kMaxPasswordLength chars');
    final limit = config.maxRoomsTotal;
    if (limit != null && _rooms.length >= limit) throw StateError(RelayErrors.roomsLimit);
    return _open(name: cleanName, did: did, pv: pv, approval: approval, password: password, ip: '', max: maxMembers ?? config.maxMembers);
  }

  Future<void> close() async {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    for (final room in _rooms.values.toList(growable: false)) {
      room.dispose();
    }
    _rooms.clear();
    for (final sock in _sockets.toList(growable: false)) {
      sock.closeNow();
    }
    _sockets.clear();
    await _http.close(force: true);
  }

  PartyRoomCreated _open({
    required String name,
    required String did,
    required int pv,
    required bool approval,
    required String? password,
    required String ip,
    required int max,
  }) {
    var code = newRoomCode();
    while (_rooms.containsKey(code)) {
      code = newRoomCode();
    }
    final room = RelayRoom(
      code: code,
      pv: pv,
      max: max,
      config: config,
      onGone: (r) {
        if (identical(_rooms[r.code], r)) _rooms.remove(r.code);
      },
      hostName: name,
      hostDid: did,
      hostIp: ip,
      approval: approval,
      password: password,
    );
    _rooms[code] = room;
    return PartyRoomCreated(code: code, token: room.hostToken, max: max, tier: config.tier);
  }

  Future<void> _onRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/v1/info') {
        return await _writeJson(req, 200, {'ev': kEnvelopeVersion, 'name': kRelayName, 'membership': config.membership, 'createPassword': config.createPassword != null});
      }
      if (req.method == 'POST' && path == '/v1/rooms') return await _postRoom(req);
      final segments = req.uri.pathSegments;
      if (req.method == 'GET' && segments.length == 3 && segments[0] == 'v1' && segments[1] == 'room') return await _upgrade(req, segments[2]);
      await _writeJson(req, 404, {'error': RelayErrors.notFound});
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _writeJson(HttpRequest req, int status, Map<String, Object?> body) async {
    final res = req.response;
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    res.write(jsonEncode(body));
    await res.close();
  }

  Future<void> _error(HttpRequest req, int status, String code) => _writeJson(req, status, {'error': code});

  Future<void> _postRoom(HttpRequest req) async {
    final ip = _clientIp(req);
    if (!_createLimiter.allow(ip, DateTime.now().millisecondsSinceEpoch)) return _error(req, 429, RelayErrors.rateLimited);
    if (req.contentLength > config.maxCreateBodyBytes) return _error(req, 400, RelayErrors.badRequest);
    final body = await _readBody(req, config.maxCreateBodyBytes);
    if (body == null) return _error(req, 400, RelayErrors.badRequest);

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } catch (_) {
      return _error(req, 400, RelayErrors.badRequest);
    }
    if (decoded is! Map<String, dynamic>) return _error(req, 400, RelayErrors.badRequest);

    final pv = decoded['pv'];
    final rawName = decoded['name'];
    final did = decoded['did'];
    if (pv is! int || pv < 1) return _error(req, 400, RelayErrors.badRequest);
    if (rawName is! String || did is! String || did.isEmpty || did.length > kMaxDidLength) return _error(req, 400, RelayErrors.badRequest);
    final name = sanitizeName(rawName);
    if (name == null) return _error(req, 400, RelayErrors.badRequest);

    var approval = false;
    String? password;
    final opts = decoded['opts'];
    if (opts != null) {
      if (opts is! Map<String, dynamic>) return _error(req, 400, RelayErrors.badRequest);
      final a = opts['approval'];
      if (a != null) {
        if (a is! bool) return _error(req, 400, RelayErrors.badRequest);
        approval = a;
      }
      final p = opts['password'];
      if (p != null) {
        if (p is! String || p.isEmpty || p.length > kMaxPasswordLength) return _error(req, 400, RelayErrors.badRequest);
        password = p;
      }
    }

    final createPassword = config.createPassword;
    if (createPassword != null) {
      final auth = decoded['auth'];
      if (auth is! Map<String, dynamic> || auth['kind'] != AuthKind.password) return _error(req, 401, RelayErrors.membershipRequired);
      final given = auth['password'];
      if (given is! String || !constantTimeEquals(createPassword, given)) return _error(req, 403, RelayErrors.badPassword);
    }

    final limit = config.maxRoomsTotal;
    if (limit != null && _rooms.length >= limit) return _error(req, 429, RelayErrors.roomsLimit);

    final created = _open(name: name, did: did, pv: pv, approval: approval, password: password, ip: ip, max: config.maxMembers);
    return _writeJson(req, 200, created.toJson());
  }

  Future<List<int>?> _readBody(HttpRequest req, int max) async {
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in req) {
        builder.add(chunk);
        if (builder.length > max) return null;
      }
    } catch (_) {
      return null;
    }
    return builder.takeBytes();
  }

  String _clientIp(HttpRequest req) {
    if (config.trustProxyHeaders) {
      final forwarded = req.headers.value('x-forwarded-for');
      if (forwarded != null) {
        final first = forwarded.split(',').first.trim();
        if (first.isNotEmpty) return first;
      }
      final cloudflare = req.headers.value('cf-connecting-ip')?.trim();
      if (cloudflare != null && cloudflare.isNotEmpty) return cloudflare;
    }
    return req.connectionInfo?.remoteAddress.address ?? '';
  }

  Future<void> _upgrade(HttpRequest req, String rawCode) async {
    final code = normalizeRoomCode(rawCode);
    final room = code == null ? null : _rooms[code];
    if (room == null) return _error(req, 404, RelayErrors.notFound);
    if (!WebSocketTransformer.isUpgradeRequest(req)) return _error(req, 400, RelayErrors.badRequest);
    final ip = _clientIp(req);
    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(req, compression: CompressionOptions.compressionOff);
    } catch (_) {
      return;
    }
    final sock = RelaySocket(ws, ip, config, DateTime.now().millisecondsSinceEpoch);
    _sockets.add(sock);
    sock.room = room.gone ? null : room;
    sock.joinTimer = Timer(config.joinTimeout, () => sock.fatal(RelayErrors.timeout));
    ws.listen(
      (Object? event) => _onFrame(sock, event),
      onError: (Object _) => _onSocketDone(sock),
      onDone: () => _onSocketDone(sock),
      cancelOnError: true,
    );
    if (sock.room == null) sock.fatal(RelayErrors.notFound);
  }

  void _onSocketDone(RelaySocket sock) {
    _sockets.remove(sock);
    sock.joinTimer?.cancel();
    sock.joinTimer = null;
    try {
      sock.room?.onSocketClosed(sock);
    } catch (_) {}
    sock.closeNow();
  }

  // -- dart:io hands over whole messages, so frame limits can only be enforced here
  void _onFrame(RelaySocket sock, Object? event) {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!sock.charge(now)) return;
      if (event is String) {
        _onText(sock, event, now);
      } else if (event is Uint8List) {
        sock.room?.handleData(sock, event);
      } else if (event is List<int>) {
        sock.room?.handleData(sock, Uint8List.fromList(event));
      }
    } catch (_) {}
  }

  void _onText(RelaySocket sock, String text, int now) {
    if (text.length > config.maxTextFrameBytes) return sock.sendError(RelayErrors.tooLarge);
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    final room = sock.room;
    if (room == null || room.gone) return sock.fatal(RelayErrors.notFound);
    if (decoded is! Map<String, dynamic>) return sock.joined ? sock.sendError(RelayErrors.badRequest) : sock.fatal(RelayErrors.badRequest);

    if (sock.joined) {
      if (decoded['t'] == Ctrl.join) return sock.sendError(RelayErrors.badRequest);
      return room.handleControl(sock, decoded);
    }
    if (sock.pending != null) {
      final type = decoded['t'];
      if (type == Ctrl.ping || type == Ctrl.leave) return room.handleControl(sock, decoded);
      return sock.sendError(RelayErrors.badRequest);
    }
    if (decoded['t'] != Ctrl.join) return sock.fatal(RelayErrors.badRequest);
    sock.joinTimer?.cancel();
    sock.joinTimer = null;
    if (!_joinLimiter.allow(sock.ip, now)) return sock.fatal(RelayErrors.rateLimited);
    room.join(sock, decoded);
  }
}

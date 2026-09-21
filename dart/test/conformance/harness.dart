import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:namida_party_relay/namida_party_relay.dart';
import 'package:test/test.dart';

/// timers the relay under test must run with, whether it is started here or pointed at with `RELAY_URL`.
const int kHostGraceMs = 1500;
const int kPendingTimeoutMs = 1500;
const int kJoinTimeoutMs = 1000;
const int kConformanceMaxMembers = 4;
const int kIpLimit = 100000;

/// the directory must not throttle its entries, the suite asserts right after every change.
const int kDirectoryRefreshMs = 0;

final int kRateDropClose = int.tryParse(Platform.environment['RATE_DROP_CLOSE'] ?? '') ?? 200;

const Duration kGrace = Duration(milliseconds: kHostGraceMs);
const Duration kFrameTimeout = Duration(seconds: 8);

final Random _random = Random();

/// the whole suite talks from one ip, so the per ip create/join limits are lifted.
PartyRelayConfig conformanceConfig() => PartyRelayConfig(
      hostGrace: const Duration(milliseconds: kHostGraceMs),
      pendingTimeout: const Duration(milliseconds: kPendingTimeoutMs),
      joinTimeout: const Duration(milliseconds: kJoinTimeoutMs),
      maxMembers: kConformanceMaxMembers,
      createLimit: kIpLimit,
      joinLimit: kIpLimit,
      listLimit: kIpLimit,
      rateDropClose: kRateDropClose,
      directoryRefreshInterval: Duration.zero,
    );

Uint8List pattern(int length) => Uint8List.fromList(List<int>.generate(length, (i) => (i * 31 + 7) & 0xFF));

void expectDataFrame(Uint8List frame, int route, int n, List<int> payload) {
  expect(dataFrameRoute(frame), route, reason: 'route');
  expect(dataFrameN(frame), n, reason: 'n');
  expect(frame.length - kDataHeaderSize, payload.length, reason: 'payload length');
  var mismatch = -1;
  for (var i = 0; i < payload.length; i++) {
    if (frame[kDataHeaderSize + i] != payload[i]) {
      mismatch = i;
      break;
    }
  }
  expect(mismatch, -1, reason: 'payload differs at byte $mismatch');
}

class CreatedRoom {
  CreatedRoom(this.code, this.token, this.max, this.tier);
  final String code;
  final String token;
  final int max;
  final String tier;
}

class HttpResult {
  HttpResult(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
  String? get error => body['error'] as String?;
}

/// one page of `GET /v1/rooms`.
class RoomListing {
  RoomListing(this.status, this.rooms, this.next);
  final int status;
  final List<Map<String, dynamic>> rooms;
  final String? next;

  Map<String, dynamic>? find(String code) {
    for (final room in rooms) {
      if (room['code'] == code) return room;
    }
    return null;
  }

  int indexOf(String code) => rooms.indexWhere((room) => room['code'] == code);
}

/// the relay under test. black box: http + websocket only.
class RelayTarget {
  RelayTarget._(this.base, this._server);

  final Uri base;
  final PartyRelayServer? _server;
  final HttpClient _http = HttpClient();
  final List<TestClient> _clients = [];

  /// `RELAY_URL` points the suite at an external relay, unless [local] is set.
  static Future<RelayTarget> start({PartyRelayConfig? config, bool local = false}) async {
    final external = Platform.environment['RELAY_URL'];
    if (!local && external != null && external.isNotEmpty) return RelayTarget._(Uri.parse(external), null);
    final server = await PartyRelayServer.start(address: InternetAddress.loopbackIPv4, config: config ?? conformanceConfig());
    return RelayTarget._(Uri.parse('http://127.0.0.1:${server.port}'), server);
  }

  /// only set when the relay runs in this process.
  PartyRelayServer? get server => _server;

  Future<void> dispose() async {
    for (final client in _clients.toList(growable: false)) {
      await client.close();
    }
    _clients.clear();
    _http.close(force: true);
    await _server?.close();
  }

  Future<HttpResult> getInfo() => _request('GET', '/v1/info', null);

  Future<HttpResult> postRoom(Object? body) => _request('POST', '/v1/rooms', body);

  Future<HttpResult> getRoomsRaw({Object? limit, String? after}) {
    final query = <String, String>{};
    if (limit != null) query['limit'] = '$limit';
    if (after != null) query['after'] = after;
    return _request('GET', '/v1/rooms', null, query);
  }

  Future<RoomListing> getRooms({Object? limit, String? after}) async {
    final result = await getRoomsRaw(limit: limit, after: after);
    final rooms = result.body['rooms'];
    return RoomListing(
      result.status,
      rooms is List ? rooms.whereType<Map<String, dynamic>>().toList(growable: false) : const [],
      result.body['next'] as String?,
    );
  }

  Future<CreatedRoom> createRoom({String name = 'host', String? did, int pv = 1, bool approval = false, String? password, bool public = false}) async {
    final result = await postRoom({
      'pv': pv,
      'name': name,
      'did': did ?? 'did-${_random.nextInt(1 << 32)}',
      'opts': {'approval': approval, 'password': password, 'public': public},
    });
    expect(result.status, 200, reason: 'create failed: ${result.body}');
    return CreatedRoom(result.body['code'] as String, result.body['token'] as String, result.body['max'] as int, result.body['tier'] as String);
  }

  Future<HttpResult> _request(String method, String path, Object? body, [Map<String, String>? query]) async {
    final req = await _http.openUrl(method, base.replace(path: path, queryParameters: query == null || query.isEmpty ? null : query));
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    return HttpResult(res.statusCode, decoded is Map<String, dynamic> ? decoded : const {});
  }

  /// raw upgrade, so a non 101 answer (404) can be inspected. a refused upgrade closes the connection, so
  /// every attempt gets its own client instead of racing a pooled one.
  Future<Object> upgrade(String code) async {
    final client = HttpClient();
    final req = await client.openUrl('GET', base.replace(path: '/v1/room/$code'));
    req.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
    req.headers.set(HttpHeaders.upgradeHeader, 'websocket');
    req.headers.set('Sec-WebSocket-Version', '13');
    req.headers.set('Sec-WebSocket-Key', base64.encode(List<int>.generate(16, (_) => _random.nextInt(256))));
    final res = await req.close();
    if (res.statusCode != HttpStatus.switchingProtocols) {
      final text = await res.transform(utf8.decoder).join();
      client.close(force: true);
      Object? decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        decoded = null;
      }
      return HttpResult(res.statusCode, decoded is Map<String, dynamic> ? decoded : const {});
    }
    return WebSocket.fromUpgradedSocket(await res.detachSocket(), serverSide: false);
  }

  Future<TestClient> connect(String code) async {
    final result = await upgrade(code);
    if (result is! WebSocket) throw StateError('upgrade refused: ${(result as HttpResult).status} ${result.body}');
    final client = TestClient._(result);
    _clients.add(client);
    return client;
  }

  /// connects and joins, expecting a `welcome`.
  Future<TestClient> join(String code, {String name = 'guest', String? did, int pv = 1, String? token, String? password}) async {
    final client = await connect(code);
    await client.join(name: name, did: did, pv: pv, token: token, password: password);
    return client;
  }
}

class TestClient {
  TestClient._(this._ws) {
    _ws.listen(
      (Object? event) {
        if (event is String) {
          _inbox.add(jsonDecode(event) as Object);
        } else if (event is List<int>) {
          _inbox.add(Uint8List.fromList(event));
        }
      },
      onError: (Object _) => _finish(),
      onDone: _finish,
      cancelOnError: false,
    );
  }

  final WebSocket _ws;
  final _Inbox _inbox = _Inbox();
  final Completer<int?> _closed = Completer<int?>();

  int n = 0;
  int _pings = 0;
  String? token;
  Map<String, dynamic>? welcome;

  Future<int?> get done => _closed.future;
  bool get isOpen => !_closed.isCompleted;
  int get queued => _inbox.length;

  void _finish() {
    _inbox.finish();
    if (!_closed.isCompleted) _closed.complete(_ws.closeCode);
  }

  void send(Map<String, Object?> frame) => _ws.add(jsonEncode(frame));

  void sendData(int route, int n, List<int> payload) => _ws.add(encodeDataFrame(route, n, payload));

  void sendRaw(List<int> bytes) => _ws.add(bytes);

  void sendText(String text) => _ws.add(text);

  Future<Map<String, dynamic>> nextText([Duration timeout = kFrameTimeout]) async {
    final item = await _inbox.take(timeout);
    if (item is! Map<String, dynamic>) throw StateError('expected a text frame, got ${item.runtimeType}');
    return item;
  }

  Future<Uint8List> nextData([Duration timeout = kFrameTimeout]) async {
    final item = await _inbox.take(timeout);
    if (item is! Uint8List) throw StateError('expected a binary frame, got $item');
    return item;
  }

  Future<Map<String, dynamic>> expectFrame(String type, [Duration timeout = kFrameTimeout]) async {
    final frame = await nextText(timeout);
    expect(frame['t'], type, reason: 'expected "$type", got $frame');
    return frame;
  }

  Future<Map<String, dynamic>> expectError(String code, {bool? fatal, Duration timeout = kFrameTimeout}) async {
    final frame = await expectFrame(Ctrl.error, timeout);
    expect(frame['code'], code, reason: 'expected error "$code", got $frame');
    if (fatal != null) expect(frame['fatal'] == true, fatal, reason: 'fatal mismatch in $frame');
    return frame;
  }

  /// fatal error + close.
  Future<Map<String, dynamic>> expectFatal(String code, [Duration timeout = kFrameTimeout]) async {
    final frame = await expectError(code, fatal: true, timeout: timeout);
    await done.timeout(timeout);
    return frame;
  }

  /// waits until everything sent before it has been handled, dropping whatever arrives meanwhile.
  Future<void> roundTrip() async {
    send({'t': Ctrl.ping, 'c': ++_pings});
    while (true) {
      final frame = await nextText();
      if (frame['t'] == Ctrl.pong) return;
    }
  }

  Future<void> expectSilence([Duration duration = const Duration(milliseconds: 250)]) async {
    await Future<void>.delayed(duration);
    expect(_inbox.length, 0, reason: 'expected no frames, got ${_inbox.peek()}');
  }

  Future<Map<String, dynamic>> join({String name = 'guest', String? did, int pv = 1, String? token, String? password}) async {
    send({'t': Ctrl.join, 'pv': pv, 'name': name, 'did': did ?? 'did-${_random.nextInt(1 << 32)}', 'token': token, 'password': password});
    final frame = await expectFrame(Ctrl.welcome);
    return adopt(frame);
  }

  /// sends a join and returns the first answer, whatever it is.
  Future<Map<String, dynamic>> joinRaw({String name = 'guest', String? did, int pv = 1, String? token, String? password}) async {
    send({'t': Ctrl.join, 'pv': pv, 'name': name, 'did': did ?? 'did-${_random.nextInt(1 << 32)}', 'token': token, 'password': password});
    return nextText();
  }

  Map<String, dynamic> adopt(Map<String, dynamic> welcomeFrame) {
    welcome = welcomeFrame;
    n = welcomeFrame['n'] as int;
    token = welcomeFrame['token'] as String;
    return welcomeFrame;
  }

  Future<void> close() async {
    try {
      await _ws.close();
    } catch (_) {}
    _finish();
  }
}

class _Inbox {
  final List<Object> _items = [];
  final List<Completer<Object>> _waiters = [];
  bool _done = false;

  int get length => _items.length;
  Object? peek() => _items.isEmpty ? null : _items.first;

  void add(Object item) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(item);
      return;
    }
    _items.add(item);
  }

  void finish() {
    _done = true;
    for (final waiter in _waiters) {
      waiter.completeError(StateError('socket closed while waiting for a frame'));
    }
    _waiters.clear();
  }

  Future<Object> take(Duration timeout) {
    if (_items.isNotEmpty) return Future.value(_items.removeAt(0));
    if (_done) return Future.error(StateError('socket closed while waiting for a frame'));
    final waiter = Completer<Object>();
    _waiters.add(waiter);
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        throw TimeoutException('no frame within $timeout');
      },
    );
  }
}
